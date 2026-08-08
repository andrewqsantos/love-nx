-- Networking acceptance harness for the love-nx Switch build.
-- Runs each check once, collects pass/fail, and renders results on screen.
-- On a Switch with wifi disabled every check must fail with a clean Lua
-- error instead of crashing or hanging.

local results = {}
local lines = {}
local done = false

local function log(msg)
	table.insert(lines, msg)
	print(msg)
end

local function check(name, fn)
	local ok, err = pcall(fn)
	if ok then
		table.insert(results, { name = name, ok = true })
		log("PASS " .. name)
	else
		table.insert(results, { name = name, ok = false, err = tostring(err) })
		log("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function expect(cond, msg)
	if not cond then error(msg, 2) end
end

local t0

local function runChecks()
	check("require socket returns table", function()
		local socket = require("socket")
		expect(type(socket) == "table", "not a table")
	end)

	check("require enet returns table", function()
		local enet = require("enet")
		expect(type(enet) == "table", "not a table")
	end)

	check("socket.gettime advances", function()
		local socket = require("socket")
		local a = socket.gettime()
		socket.sleep(0.05)
		local b = socket.gettime()
		expect(b > a, string.format("did not advance: %s -> %s", a, b))
	end)

	check("udp setpeername/getsockname", function()
		local socket = require("socket")
		local udp = socket.udp()
		expect(udp, "socket.udp() returned nil")
		expect(udp:setpeername("192.0.2.1", 9), "setpeername failed")
		local ip, port = udp:getsockname()
		udp:close()
		expect(ip and ip ~= "0.0.0.0", "getsockname gave " .. tostring(ip))
		expect(port ~= nil, "no port")
		log("  LAN IP: " .. tostring(ip) .. ":" .. tostring(port))
	end)

	check("tcp connect/send/receive relay 7778", function()
		local socket = require("socket")
		local tcp = socket.tcp()
		expect(tcp, "socket.tcp() returned nil")
		tcp:settimeout(10)
		local ok, err = tcp:connect("147.182.215.255", 7778)
		expect(ok, "connect: " .. tostring(err))
		tcp:send('{"hello":"love-nx"}\n')
		local line, rerr = tcp:receive("*l")
		tcp:close()
		expect(line, "receive: " .. tostring(rerr))
		log("  relay said: " .. tostring(line))
	end)

	check("tcp timeout error string", function()
		local socket = require("socket")
		local tcp = socket.tcp()
		-- 192.0.2.1 is TEST-NET-1: guaranteed unroutable, connect must
		-- time out rather than error instantly.
		tcp:settimeout(1)
		local ok, err = tcp:connect("192.0.2.1", 65000)
		tcp:close()
		expect(ok == nil, "connect unexpectedly succeeded")
		expect(err == "timeout", "want 'timeout', got " .. tostring(err))
	end)

	check("enet host_create client", function()
		local enet = require("enet")
		local host = enet.host_create()
		expect(host, "host_create() returned nil")
		host:destroy()
	end)

	check("enet host_create :7777 bind", function()
		local enet = require("enet")
		local host = enet.host_create(":7777", 32, 2)
		expect(host, "host_create(:7777) returned nil")
		host:destroy()
	end)

	check("enet loopback round-trip", function()
		local enet = require("enet")
		local server = enet.host_create("127.0.0.1:7779", 4, 2)
		local client = enet.host_create()
		expect(server and client, "host create failed")
		local peer = client:connect("127.0.0.1:7779", 2)
		expect(peer, "connect returned nil")
		local connected = false
		local got = nil
		local deadline = os.clock() + 5
		while os.clock() < deadline and not got do
			local ev = server:service(100)
			while ev do
				if ev.type == "connect" then
					connected = true
				elseif ev.type == "receive" then
					got = ev.data
					ev.peer:send("ack:" .. ev.data, ev.channel, "reliable")
				end
				ev = server:service(0)
			end
			local cev = client:service(100)
			while cev do
				if cev.type == "connect" then
					peer:send("ping", 0, "reliable")
				end
				cev = client:service(0)
			end
			if not connected then client:flush() end
		end
		server:destroy()
		client:destroy()
		expect(connected, "server never saw connect")
		expect(got == "ping", "server got " .. tostring(got))
	end)

	check("love.system.httpDownload exists", function()
		expect(type(love.system.httpDownload) == "function", "missing")
	end)

	check("httpDownload https://api.github.com/zen", function()
		if type(love.system.httpDownload) ~= "function" then
			error("httpDownload missing")
		end
		local ok, res = love.system.httpDownload("https://api.github.com/zen", "/net-test-zen.txt")
		expect(ok == true, "download failed: " .. tostring(res))
		expect(type(res) == "number" and res >= 200 and res < 300, "status " .. tostring(res))
		local content = love.filesystem.read("/net-test-zen.txt")
		expect(content and #content > 0, "empty file")
		log("  zen: " .. content:gsub("%s+$", ""))
	end)

	check("httpDownload offline-safe failure", function()
		if type(love.system.httpDownload) ~= "function" then
			error("httpDownload missing")
		end
		-- Port 9 discard on TEST-NET-1: unroutable, must fail cleanly.
		local ok, err = love.system.httpDownload("https://192.0.2.1/", "/net-test-never.txt")
		expect(ok == false, "unexpectedly succeeded")
		expect(type(err) == "string" and #err > 0, "no error string")
		log("  clean failure: " .. err)
	end)

	check("love.thread + Channel", function()
		expect(love.thread and love.thread.newThread, "love.thread missing")
		local channel = love.thread.getChannel("net-test")
		expect(channel, "getChannel failed")
		local code = [[
			local channel = love.thread.getChannel("net-test")
			local v = channel:pop()
			channel:push(v * 2)
		]]
		local thread = love.thread.newThread(code)
		expect(thread, "newThread failed")
		channel:push(21)
		thread:start()
		local deadline = os.clock() + 5
		local got
		while os.clock() < deadline do
			got = channel:pop()
			if got ~= nil then break end
		end
		expect(got == 42, "channel round-trip gave " .. tostring(got))
	end)

	done = true
end

function love.load()
	t0 = love.timer and love.timer.getTime() or os.clock()
	runChecks()
end

function love.draw()
	love.graphics.clear(0.1, 0.1, 0.12)
	local y = 20
	love.graphics.print("love-nx networking acceptance " .. (done and "(done)" or "(running)"), 20, y)
	y = y + 30
	for _, r in ipairs(results) do
		if r.ok then
			love.graphics.setColor(0.3, 0.9, 0.3)
		else
			love.graphics.setColor(0.95, 0.35, 0.35)
		end
		love.graphics.print((r.ok and "PASS " or "FAIL ") .. r.name .. (r.err and (" — " .. r.err) or ""), 20, y)
		y = y + 22
	end
	love.graphics.setColor(0.8, 0.8, 0.8)
	for _, l in ipairs(lines) do
		if l:sub(1, 2) == "  " then
			love.graphics.print(l, 40, y)
			y = y + 20
		end
	end
end
