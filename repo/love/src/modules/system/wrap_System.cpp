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

struct HttpDownloadTarget
{
	filesystem::File *file = nullptr;
	bool writeFailed = false;
};

static size_t httpDownloadWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
	HttpDownloadTarget *target = (HttpDownloadTarget *) userdata;
	size_t total = size * nmemb;

	if (total > 0 && !target->file->write(ptr, (int64) total))
	{
		target->writeFailed = true;
		return 0; // abort the transfer
	}

	return total;
}

int w_httpDownload(lua_State *L)
{
	std::string url = luax_checkstring(L, 1);
	std::string destination = luax_checkstring(L, 2);

	// Optional table of request headers, as key-value pairs.
	std::vector<std::string> headers;
	bool hasUserAgent = false;
	if (lua_istable(L, 3))
	{
		lua_pushnil(L);
		while (lua_next(L, 3) != 0)
		{
			const char *value = lua_tostring(L, -1);
			if (lua_type(L, -2) == LUA_TSTRING && value != nullptr)
			{
				const char *key = lua_tostring(L, -2);
				headers.push_back(std::string(key) + ": " + value);
				if (strcasecmp(key, "User-Agent") == 0)
					hasUserAgent = true;
			}
			lua_pop(L, 1);
		}
	}

	std::call_once(curlInitOnce, []() { curl_global_init(CURL_GLOBAL_DEFAULT); });

	auto fs = Module::getInstance<filesystem::Filesystem>(Module::M_FILESYSTEM);
	if (fs == nullptr)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "love.filesystem is not initialized");
		return 2;
	}

	StrongRef<filesystem::File> file(fs->newFile(destination.c_str()), Acquire::NORETAIN);
	if (!file->open(filesystem::File::MODE_WRITE))
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not open destination file for writing");
		return 2;
	}

	HttpDownloadTarget target;
	target.file = file.get();

	CURL *curl = curl_easy_init();
	if (curl == nullptr)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not initialize curl");
		return 2;
	}

	struct curl_slist *requestHeaders = nullptr;
	for (const std::string &header : headers)
		requestHeaders = curl_slist_append(requestHeaders, header.c_str());

	curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, httpDownloadWriteCallback);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, &target);
	curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
	curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
	curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
	if (!hasUserAgent)
		curl_easy_setopt(curl, CURLOPT_USERAGENT, "love-nx/" LOVE_VERSION_STRING);
	// TLS verification stays enabled; the CA bundle is bundled in romfs.
	curl_easy_setopt(curl, CURLOPT_CAINFO, "romfs:/cacert.pem");

	if (requestHeaders != nullptr)
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, requestHeaders);

	CURLcode result = curl_easy_perform(curl);

	long status = 0;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

	if (requestHeaders != nullptr)
		curl_slist_free_all(requestHeaders);
	curl_easy_cleanup(curl);

	bool closed = target.file->close();

	if (result != CURLE_OK)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, target.writeFailed && result == CURLE_WRITE_ERROR
			? "could not write to destination file"
			: curl_easy_strerror(result));
		return 2;
	}

	if (!closed)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "could not flush destination file");
		return 2;
	}

	if (status < 200 || status >= 300)
	{
		lua_pushboolean(L, false);
		luax_pushstring(L, "HTTP status " + std::to_string(status));
		return 2;
	}

	lua_pushboolean(L, true);
	lua_pushinteger(L, status);
	return 2;
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
