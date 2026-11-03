/**
 * Copyright (c) 2006-2023 LOVE Development Team
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 **/

// LOVE
#include "wrap_System.h"
#include "sdl/System.h"

#ifdef LOVE_NX
#include "common/config.h"
#include "common/version.h"
#include "modules/filesystem/Filesystem.h"

#include <curl/curl.h>

#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <strings.h>
#include <mutex>
#include <string>
#include <vector>
#endif

namespace love
{
namespace system
{

#define instance() (Module::getInstance<System>(Module::M_SYSTEM))

#ifdef LOVE_NX

static std::once_flag curlInitOnce;
static CURLcode curlInitResult = CURLE_FAILED_INIT;
static std::atomic<unsigned long> httpDownloadCounter(0);

static const size_t HTTP_DOWNLOAD_MAX_BYTES = 128 * 1024 * 1024;
static const size_t HTTP_REQUEST_MAX_BODY_BYTES = 16 * 1024 * 1024;
static const size_t HTTP_RESPONSE_MAX_BYTES = 2 * 1024 * 1024;
static const long HTTP_DOWNLOAD_TIMEOUT_SECONDS = 120;
static const long HTTP_CONNECT_TIMEOUT_SECONDS = 15;
static const long HTTP_DEFAULT_REQUEST_TIMEOUT_SECONDS = 30;
static const long HTTP_MAX_REQUEST_TIMEOUT_SECONDS = 120;

static bool readLuaString(lua_State *L, int index, std::string &value)
{
	if (lua_type(L, index) != LUA_TSTRING)
		return false;

	size_t length = 0;
	const char *data = lua_tolstring(L, index, &length);
	if (data == nullptr || std::memchr(data, '\0', length) != nullptr)
		return false;

	value.assign(data, length);
	return true;
}

static bool isHttpsURL(const std::string &url)
{
	static const char prefix[] = "https://";
	if (url.size() <= sizeof(prefix) - 1)
		return false;

	for (size_t i = 0; i < sizeof(prefix) - 1; i++)
	{
		if (std::tolower((unsigned char) url[i]) != prefix[i])
			return false;
	}

	size_t authorityEnd = url.find_first_of("/?#", sizeof(prefix) - 1);
	size_t authoritySize = (authorityEnd == std::string::npos ? url.size() : authorityEnd)
		- (sizeof(prefix) - 1);
	if (authoritySize == 0)
		return false;
	if (url.substr(sizeof(prefix) - 1, authoritySize).find('@') != std::string::npos)
		return false;

	for (unsigned char c : url)
	{
		if (c <= 0x20 || c == 0x7f)
			return false;
	}

	return true;
}

static bool isSafeSavePath(std::string &path)
{
	if (path.empty() || path.size() > 900 || path.find('\0') != std::string::npos
		|| path.find('\\') != std::string::npos || path.find(':') != std::string::npos)
		return false;

	// LÖVE accepts a leading slash for virtual filesystem paths; remove it so
	// the destination is always interpreted relative to the save directory.
	while (!path.empty() && path[0] == '/')
		path.erase(0, 1);

	if (path.empty() || path[path.size() - 1] == '/')
		return false;

	size_t start = 0;
	while (start <= path.size())
	{
		size_t end = path.find('/', start);
		if (end == std::string::npos)
			end = path.size();

		std::string component = path.substr(start, end - start);
		if (component.empty() || component == "." || component == "..")
			return false;

		if (end == path.size())
			break;
		start = end + 1;
	}

	return true;
}

static bool isValidHeaderName(const std::string &name)
{
	if (name.empty() || name.size() > 256)
		return false;

	for (unsigned char c : name)
	{
		bool alphanumeric = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
			|| (c >= '0' && c <= '9');
		if (!(alphanumeric || c == '!' || c == '#' || c == '$' || c == '%'
			|| c == '&' || c == '\'' || c == '*' || c == '+' || c == '-'
			|| c == '.' || c == '^' || c == '_' || c == '`' || c == '|'
			|| c == '~'))
			return false;
	}

	return true;
}

static bool isValidHeaderValue(const std::string &value)
{
	if (value.size() > 8192)
		return false;

	for (unsigned char c : value)
	{
		if ((c < 0x20 && c != '\t') || c == 0x7f)
			return false;
	}

	return true;
}

static bool collectHeaders(lua_State *L, int index, std::vector<std::string> &headers, bool &hasUserAgent)
{
	if (lua_isnoneornil(L, index))
		return true;

	if (!lua_istable(L, index))
		return false;

	lua_pushnil(L);
	while (lua_next(L, index) != 0)
	{
		std::string name;
		std::string value;
		bool valid = readLuaString(L, -2, name) && readLuaString(L, -1, value)
			&& isValidHeaderName(name) && isValidHeaderValue(value);

		lua_pop(L, 1);
		if (!valid || headers.size() >= 64)
		{
			lua_pop(L, 1);
			return false;
		}

		if (strcasecmp(name.c_str(), "User-Agent") == 0)
			hasUserAgent = true;
		headers.push_back(name + ": " + value);
	}

	return true;
}

static bool collectHeaderPairs(lua_State *L, int index, std::vector<std::string> &headers, bool &hasUserAgent)
{
	if (lua_isnoneornil(L, index))
		return true;

	if (!lua_istable(L, index))
		return false;

	size_t count = lua_objlen(L, index);
	if (count > 128 || count % 2 != 0)
		return false;

	size_t actualCount = 0;
	lua_pushnil(L);
	while (lua_next(L, index) != 0)
	{
		bool validKey = lua_type(L, -2) == LUA_TNUMBER;
		lua_Number keyValue = validKey ? lua_tonumber(L, -2) : 0;
		lua_Integer key = validKey ? lua_tointeger(L, -2) : 0;
		validKey = validKey && key >= 1 && (size_t) key <= count && (lua_Number) key == keyValue;
		lua_pop(L, 1);
		if (!validKey)
		{
			lua_pop(L, 1);
			return false;
		}
		actualCount++;
	}

	if (actualCount != count)
		return false;

	for (size_t i = 1; i <= count; i += 2)
	{
		lua_rawgeti(L, index, (int) i);
		std::string name;
		bool valid = readLuaString(L, -1, name);
		lua_pop(L, 1);

		lua_rawgeti(L, index, (int) (i + 1));
		std::string value;
		valid = valid && readLuaString(L, -1, value);
		lua_pop(L, 1);

		valid = valid && isValidHeaderName(name) && isValidHeaderValue(value);
		if (!valid)
			return false;

		if (strcasecmp(name.c_str(), "User-Agent") == 0)
			hasUserAgent = true;
		headers.push_back(name + ": " + value);
	}

	return true;
}

template <typename T>
static bool setCurlOption(CURL *curl, CURLoption option, T value, std::string &error)
{
	CURLcode result = curl_easy_setopt(curl, option, value);
	if (result == CURLE_OK)
		return true;

	error = curl_easy_strerror(result);
	return false;
}

static bool configureHttpsCurl(CURL *curl, const std::string &url,
	long timeoutSeconds, bool allowRedirects, bool addUserAgent, std::string &error)
{
	if (!setCurlOption(curl, CURLOPT_URL, url.c_str(), error)
		|| !setCurlOption(curl, CURLOPT_NOSIGNAL, 1L, error)
		|| !setCurlOption(curl, CURLOPT_CONNECTTIMEOUT, HTTP_CONNECT_TIMEOUT_SECONDS, error)
		|| !setCurlOption(curl, CURLOPT_TIMEOUT, timeoutSeconds, error)
		|| !setCurlOption(curl, CURLOPT_SSL_VERIFYPEER, 1L, error)
		|| !setCurlOption(curl, CURLOPT_SSL_VERIFYHOST, 2L, error)
		|| !setCurlOption(curl, CURLOPT_CAINFO, "romfs:/cacert.pem", error)
		|| !setCurlOption(curl, CURLOPT_PROTOCOLS, (long) CURLPROTO_HTTPS, error)
		|| !setCurlOption(curl, CURLOPT_REDIR_PROTOCOLS, (long) CURLPROTO_HTTPS, error)
		|| !setCurlOption(curl, CURLOPT_FOLLOWLOCATION, allowRedirects ? 1L : 0L, error)
		|| !setCurlOption(curl, CURLOPT_MAXREDIRS, 5L, error))
		return false;

	if (addUserAgent && !setCurlOption(curl, CURLOPT_USERAGENT, "love-nx/" LOVE_VERSION_STRING, error))
		return false;

	return true;
}

struct HttpDownloadTarget
{
	filesystem::File *file = nullptr;
	bool writeFailed = false;
	bool tooLarge = false;
	size_t bytesWritten = 0;
};

static size_t httpDownloadWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
	HttpDownloadTarget *target = (HttpDownloadTarget *) userdata;
	if (size != 0 && nmemb > std::numeric_limits<size_t>::max() / size)
		return 0;
	size_t total = size * nmemb;

	if (total > HTTP_DOWNLOAD_MAX_BYTES - target->bytesWritten)
	{
		target->tooLarge = true;
		return 0;
	}

	try
	{
		if (total > 0 && !target->file->write(ptr, (int64) total))
		{
			target->writeFailed = true;
			return 0;
		}
	}
	catch (...)
	{
		target->writeFailed = true;
		return 0;
	}

	target->bytesWritten += total;

	return total;
}

struct HttpResponseTarget
{
	std::string body;
	bool tooLarge = false;
	bool writeFailed = false;
};

static size_t httpResponseWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
	HttpResponseTarget *target = (HttpResponseTarget *) userdata;
	if (size != 0 && nmemb > std::numeric_limits<size_t>::max() / size)
		return 0;
	size_t total = size * nmemb;

	if (total > HTTP_RESPONSE_MAX_BYTES - target->body.size())
	{
		target->tooLarge = true;
		return 0;
	}

	try
	{
		target->body.append(ptr, total);
	}
	catch (...)
	{
		target->writeFailed = true;
		return 0;
	}

	return total;
}

static bool initializeCurl(std::string &error)
{
	std::call_once(curlInitOnce, []() { curlInitResult = curl_global_init(CURL_GLOBAL_DEFAULT); });
	if (curlInitResult == CURLE_OK)
		return true;

	error = curl_easy_strerror(curlInitResult);
	return false;
}

int w_httpDownload(lua_State *L)
{
	std::string url;
	std::string destination;
	if (!readLuaString(L, 1, url) || url.size() > 8192 || !isHttpsURL(url))
		return luaL_argerror(L, 1, "must be a valid HTTPS URL");
	if (!readLuaString(L, 2, destination) || !isSafeSavePath(destination))
		return luaL_argerror(L, 2, "must be a save-relative path without traversal");

	// Optional table of request headers, as key-value pairs.
	std::vector<std::string> headers;
	bool hasUserAgent = false;
	if (!collectHeaders(L, 3, headers, hasUserAgent))
		return luaL_argerror(L, 3, "must be a table of valid string headers");

	std::string error;
	if (!initializeCurl(error))
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, error);
		return 2;
	}

	auto fs = Module::getInstance<filesystem::Filesystem>(Module::M_FILESYSTEM);
	if (fs == nullptr)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "love.filesystem is not initialized");
		return 2;
	}

	std::string temporaryDestination = destination + ".love-http-" +
		std::to_string(httpDownloadCounter.fetch_add(1));
	StrongRef<filesystem::File> file(fs->newFile(temporaryDestination.c_str()), Acquire::NORETAIN);
	if (!file->open(filesystem::File::MODE_WRITE))
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not open destination file for writing");
		return 2;
	}

	HttpDownloadTarget target;
	target.file = file.get();

	CURL *curl = curl_easy_init();
	if (curl == nullptr)
	{
		target.file->close();
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not initialize curl");
		return 2;
	}

	struct curl_slist *requestHeaders = nullptr;
	for (const std::string &header : headers)
	{
		struct curl_slist *newHeaders = curl_slist_append(requestHeaders, header.c_str());
		if (newHeaders == nullptr)
		{
			if (requestHeaders != nullptr)
				curl_slist_free_all(requestHeaders);
			curl_easy_cleanup(curl);
			target.file->close();
			fs->remove(temporaryDestination.c_str());
			lua_pushboolean(L, false);
			luax_pushstring(L, "could not allocate request headers");
			return 2;
		}
		requestHeaders = newHeaders;
	}

	bool configured = configureHttpsCurl(curl, url,
		HTTP_DOWNLOAD_TIMEOUT_SECONDS, headers.empty(), !hasUserAgent, error)
		&& setCurlOption(curl, CURLOPT_WRITEFUNCTION, httpDownloadWriteCallback, error)
		&& setCurlOption(curl, CURLOPT_WRITEDATA, &target, error);
	if (configured && requestHeaders != nullptr)
		configured = setCurlOption(curl, CURLOPT_HTTPHEADER, requestHeaders, error);

	CURLcode result = configured ? curl_easy_perform(curl) : CURLE_FAILED_INIT;

	long status = 0;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

	if (requestHeaders != nullptr)
		curl_slist_free_all(requestHeaders);
	curl_easy_cleanup(curl);

	bool closed = target.file->close();

	if (result != CURLE_OK)
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		if (target.tooLarge)
			luax_pushstring(L, "download exceeds the 128 MiB limit");
		else if (target.writeFailed)
			luax_pushstring(L, "could not write to destination file");
		else
			luax_pushstring(L, configured ? curl_easy_strerror(result) : error);
		return 2;
	}

	if (!closed)
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not flush destination file");
		return 2;
	}

	if (status < 200 || status >= 300)
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "HTTP status " + std::to_string(status));
		return 2;
	}

	std::string saveDirectory = fs->getSaveDirectory();
	if (saveDirectory.empty())
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "save directory is not available");
		return 2;
	}
	if (saveDirectory[saveDirectory.size() - 1] != '/')
		saveDirectory += "/";
	std::string temporaryFullPath = saveDirectory + temporaryDestination;
	std::string destinationFullPath = saveDirectory + destination;
	if (std::rename(temporaryFullPath.c_str(), destinationFullPath.c_str()) != 0)
	{
		fs->remove(temporaryDestination.c_str());
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not replace destination file");
		return 2;
	}

	lua_pushboolean(L, true);
	lua_pushinteger(L, status);
	return 2;
}

// HostShell consumes a single STATUS/ERROR envelope from this bridge.
int w_httpRequest(lua_State *L)
{
	std::string url;
	std::string method;
	std::string body;
	std::string userAgent;
	bool hasBody = !lua_isnoneornil(L, 4);
	if (!readLuaString(L, 1, url) || url.size() > 8192 || !isHttpsURL(url))
		return luaL_argerror(L, 1, "must be a valid HTTPS URL");
	if (!readLuaString(L, 2, method))
		return luaL_argerror(L, 2, "must be GET, POST, PUT, or DELETE");
	if (strcasecmp(method.c_str(), "GET") == 0)
		method = "GET";
	else if (strcasecmp(method.c_str(), "POST") == 0)
		method = "POST";
	else if (strcasecmp(method.c_str(), "PUT") == 0)
		method = "PUT";
	else if (strcasecmp(method.c_str(), "DELETE") == 0)
		method = "DELETE";
	else
		return luaL_argerror(L, 2, "must be GET, POST, PUT, or DELETE");

	std::vector<std::string> headers;
	bool hasUserAgent = false;
	if (!collectHeaderPairs(L, 3, headers, hasUserAgent))
		return luaL_argerror(L, 3, "must be an alternating array of valid header names and values");

	if (hasBody)
	{
		if (lua_type(L, 4) != LUA_TSTRING)
			return luaL_argerror(L, 4, "must be a string no larger than 16 MiB");
		size_t bodyLength = 0;
		const char *bodyData = lua_tolstring(L, 4, &bodyLength);
		if (bodyLength > HTTP_REQUEST_MAX_BODY_BYTES)
			return luaL_argerror(L, 4, "must be a string no larger than 16 MiB");
		body.assign(bodyData, bodyLength);
	}

	if (!lua_isnoneornil(L, 5))
	{
		if (!readLuaString(L, 5, userAgent) || userAgent.size() > 1024 || !isValidHeaderValue(userAgent))
			return luaL_argerror(L, 5, "must be a valid User-Agent string");
	}
	if (hasUserAgent && !userAgent.empty())
		return luaL_argerror(L, 5, "User-Agent must be set either in fields or userAgent, not both");

	long timeoutSeconds = HTTP_DEFAULT_REQUEST_TIMEOUT_SECONDS;
	if (!lua_isnoneornil(L, 6))
	{
		lua_Number timeout = luaL_checknumber(L, 6);
		if (!std::isfinite((double) timeout) || timeout < 1.0 || timeout > HTTP_MAX_REQUEST_TIMEOUT_SECONDS)
			return luaL_argerror(L, 6, "must be between 1 and 120 seconds");
		timeoutSeconds = (long) timeout;
	}

	std::string error;
	if (!initializeCurl(error))
	{
		std::string response = "ERROR " + error + "\n";
		lua_pushlstring(L, response.data(), response.size());
		return 1;
	}

	CURL *curl = curl_easy_init();
	if (curl == nullptr)
	{
		const char *message = "ERROR could not initialize curl\n";
		lua_pushlstring(L, message, std::strlen(message));
		return 1;
	}

	struct curl_slist *requestHeaders = nullptr;
	for (const std::string &header : headers)
	{
		struct curl_slist *newHeaders = curl_slist_append(requestHeaders, header.c_str());
		if (newHeaders == nullptr)
		{
			if (requestHeaders != nullptr)
				curl_slist_free_all(requestHeaders);
			curl_easy_cleanup(curl);
			const char *message = "ERROR could not allocate request headers\n";
			lua_pushlstring(L, message, std::strlen(message));
			return 1;
		}
		requestHeaders = newHeaders;
	}

	HttpResponseTarget response;
	bool configured = configureHttpsCurl(curl, url, timeoutSeconds,
		false, userAgent.empty() && !hasUserAgent, error)
		&& setCurlOption(curl, CURLOPT_WRITEFUNCTION, httpResponseWriteCallback, error)
		&& setCurlOption(curl, CURLOPT_WRITEDATA, &response, error);
	if (configured && !userAgent.empty())
		configured = setCurlOption(curl, CURLOPT_USERAGENT, userAgent.c_str(), error);
	if (configured && (hasBody || strcasecmp(method.c_str(), "POST") == 0))
	{
		configured = setCurlOption(curl, CURLOPT_POSTFIELDS, body.c_str(), error)
			&& setCurlOption(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t) body.size(), error);
	}
	if (configured)
		configured = setCurlOption(curl, CURLOPT_CUSTOMREQUEST, method.c_str(), error);
	if (configured && requestHeaders != nullptr)
		configured = setCurlOption(curl, CURLOPT_HTTPHEADER, requestHeaders, error);

	CURLcode result = configured ? curl_easy_perform(curl) : CURLE_FAILED_INIT;
	long status = 0;
	CURLcode infoResult = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
	if (result == CURLE_OK && infoResult != CURLE_OK)
		result = infoResult;

	if (requestHeaders != nullptr)
		curl_slist_free_all(requestHeaders);
	curl_easy_cleanup(curl);

	if (result != CURLE_OK)
	{
		std::string message;
		if (response.tooLarge)
			message = "HTTP response exceeds the 2 MiB limit";
		else if (response.writeFailed)
			message = "could not buffer HTTP response";
		else
			message = configured ? curl_easy_strerror(result) : error;
		std::string envelope = "ERROR " + message + "\n";
		lua_pushlstring(L, envelope.data(), envelope.size());
		return 1;
	}

	if (status < 100 || status > 999)
	{
		const char *message = "ERROR HTTP response did not include a valid status\n";
		lua_pushlstring(L, message, std::strlen(message));
		return 1;
	}

	char statusText[4];
	std::snprintf(statusText, sizeof(statusText), "%03ld", status);
	std::string envelope = "STATUS " + std::string(statusText) + "\n" + response.body;
	lua_pushlstring(L, envelope.data(), envelope.size());
	return 1;
}

#endif // LOVE_NX


int w_getOS(lua_State *L)
{
	luax_pushstring(L, instance()->getOS());
	return 1;
}

int w_getProcessorCount(lua_State *L)
{
	lua_pushinteger(L, instance()->getProcessorCount());
	return 1;
}

int w_setClipboardText(lua_State *L)
{
	const char *text = luaL_checkstring(L, 1);
	luax_catchexcept(L, [&]() { instance()->setClipboardText(text); });
	return 0;
}

int w_getClipboardText(lua_State *L)
{
	std::string text;
	luax_catchexcept(L, [&]() { text = instance()->getClipboardText(); });
	luax_pushstring(L, text);
	return 1;
}

int w_getPowerInfo(lua_State *L)
{
	int seconds = -1, percent = -1;
	const char *str;

	System::PowerState state = instance()->getPowerInfo(seconds, percent);

	if (!System::getConstant(state, str))
		str = "unknown";

	lua_pushstring(L, str);

	if (percent >= 0)
		lua_pushinteger(L, percent);
	else
		lua_pushnil(L);

	if (seconds >= 0)
		lua_pushinteger(L, seconds);
	else
		lua_pushnil(L);

	return 3;
}

int w_openURL(lua_State *L)
{
	std::string url = luax_checkstring(L, 1);
	luax_pushboolean(L, instance()->openURL(url));
	return 1;
}

int w_vibrate(lua_State *L)
{
	double seconds = luaL_optnumber(L, 1, 0.5);
	instance()->vibrate(seconds);
	return 0;
}

int w_hasBackgroundMusic(lua_State *L)
{
	lua_pushboolean(L, instance()->hasBackgroundMusic());
	return 1;
}

static const luaL_Reg functions[] =
{
	{ "getOS", w_getOS },
	{ "getProcessorCount", w_getProcessorCount },
	{ "setClipboardText", w_setClipboardText },
	{ "getClipboardText", w_getClipboardText },
	{ "getPowerInfo", w_getPowerInfo },
	{ "openURL", w_openURL },
	{ "vibrate", w_vibrate },
	{ "hasBackgroundMusic", w_hasBackgroundMusic },
#ifdef LOVE_NX
	{ "httpDownload", w_httpDownload },
	{ "httpRequest", w_httpRequest },
#endif
	{ 0, 0 }
};

extern "C" int luaopen_love_system(lua_State *L)
{
	System *instance = instance();
	if (instance == nullptr)
	{
		instance = new love::system::sdl::System();
	}
	else
		instance->retain();

	WrappedModule w;
	w.module = instance;
	w.name = "system";
	w.type = &Module::type;
	w.functions = functions;
	w.types = nullptr;

	return luax_register_module(L, w);
}

} // system
} // love
