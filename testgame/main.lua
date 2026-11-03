-- Networking acceptance harness for the love-nx Switch build.
-- Runs each check once, collects pass/fail, and renders results on screen.
-- On a Switch with wifi disabled every check must fail with a clean Lua
-- error instead of crashing or hanging.

-- Operator knobs for PC-side helpers (leave empty to skip those checks).
local PC_TCP_HOST = "" -- set to your PC LAN IP to enable tcp pc relay
local PC_TCP_PORT = 7778
local PC_ENET_HOLD = true -- keep :7777 hosted after checks for pc_enet_peer.py

local results = {}
local lines = {}
local done = false
local lan_ip = nil
local live_enet_host = nil

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
		lan_ip = ip
		log("  LAN IP: " .. tostring(ip) .. ":" .. tostring(port))
	end)

	-- Same-console TCP listen+connect is unreliable on some libnx setups
	-- (SO_REUSEADDR / hairpin to own LAN IP). Prefer PC relay as stack proof.
	check("tcp local echo (best-effort)", function()
		expect(lan_ip, "no LAN IP from udp check")
		local socket = require("socket")
		local port = 17890
		local server = socket.tcp()
		expect(server, "server tcp() nil")
		server:settimeout(3)
		-- libnx may reject reuseaddr; bind still works without it.
		pcall(function() server:setoption("reuseaddr", true) end)
		local bok, berr = server:bind("*", port)
		expect(bok, "bind: " .. tostring(berr))
		expect(server:listen(1), "listen failed")

		local client = socket.tcp()
		expect(client, "client tcp() nil")
		client:settimeout(3)
		local cok, cerr = client:connect(lan_ip, port)
		if not cok then
			server:close()
			client:close()
			error("self-connect unsupported on this console: " .. tostring(cerr)
				.. " (TCP stack already proven if tcp pc relay PASSed)", 0)
		end

		local peer = server:accept()
		expect(peer, "accept returned nil")
		peer:settimeout(3)

		local payload = '{"hello":"love-nx"}\n'
		local sent, serr = client:send(payload)
		expect(sent == #payload, "send: " .. tostring(serr) .. " sent=" .. tostring(sent))

		local line, rerr = peer:receive("*l")
		expect(line, "server receive: " .. tostring(rerr))
		local reply = "ack:" .. line .. "\n"
		local rsent, rserr = peer:send(reply)
		expect(rsent == #reply, "peer send: " .. tostring(rserr))

		local got, gerr = client:receive("*l")
		client:close()
		peer:close()
		server:close()
		expect(got == "ack:" .. line, "client receive: " .. tostring(gerr) .. " got=" .. tostring(got))
		log("  local echo: " .. tostring(got))
	end)

	if PC_TCP_HOST ~= "" then
		check("tcp pc relay " .. PC_TCP_HOST .. ":" .. PC_TCP_PORT, function()
			local socket = require("socket")
			local tcp = socket.tcp()
			expect(tcp, "socket.tcp() returned nil")
			tcp:settimeout(10)
			local ok, err = tcp:connect(PC_TCP_HOST, PC_TCP_PORT)
			expect(ok, "connect: " .. tostring(err))
			local payload = '{"hello":"love-nx"}\n'
			local sent, serr = tcp:send(payload)
			expect(sent == #payload, "send: " .. tostring(serr) .. " sent=" .. tostring(sent))
			local line, rerr = tcp:receive("*l")
			tcp:close()
			expect(line, "receive: " .. tostring(rerr))
			log("  pc relay said: " .. tostring(line))
		end)
	else
		log("  skip tcp pc relay (set PC_TCP_HOST in main.lua)")
	end

	check("tcp remote relay 7778 (optional)", function()
		local socket = require("socket")
		local tcp = socket.tcp()
		expect(tcp, "socket.tcp() returned nil")
		tcp:settimeout(10)
		local ok, err = tcp:connect("147.182.215.255", 7778)
		expect(ok, "connect: " .. tostring(err))
		local payload = '{"hello":"love-nx"}\n'
		local sent, serr = tcp:send(payload)
		expect(sent == #payload, "send: " .. tostring(serr) .. " sent=" .. tostring(sent))
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

	check("enet LAN round-trip (best-effort)", function()
		expect(lan_ip, "no LAN IP from udp check")
		local enet = require("enet")
		local server = enet.host_create("*:7779", 4, 2)
		local client = enet.host_create()
		expect(server and client, "host create failed")
		local peer = client:connect(lan_ip .. ":7779", 2)
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
		if not connected then
			error("same-console ENet hairpin failed (use pc_enet_peer.py client "
				.. lan_ip .. " against live :7777)", 0)
		end
		expect(got == "ping", "server got " .. tostring(got))
		log("  enet LAN via " .. lan_ip .. ":7779")
	end)

	check("love.system.httpDownload exists", function()
		expect(type(love.system.httpDownload) == "function", "missing")
	end)

	check("love.system.httpRequest exists", function()
		expect(type(love.system.httpRequest) == "function", "missing")
	end)

	check("httpRequest HTTPS response", function()
		if type(love.system.httpRequest) ~= "function" then
			error("httpRequest missing")
		end
		local response = love.system.httpRequest(
			"https://api.github.com/zen",
			"GET",
			{ "X-Signature", "opaque-test-signature" },
			nil,
			"love-nx-test",
			15
		)
		local status, body = response:match("^STATUS (%d%d%d)\n(.*)$")
		expect(status == "200", "unexpected response: " .. tostring(response))
		expect(type(body) == "string" and #body > 0, "empty response")
		log("  zen: " .. body:gsub("%s+$", ""))
	end)

	check("httpRequest rejects cleartext URLs", function()
		local ok = pcall(function()
			love.system.httpRequest("http://example.invalid/", "GET")
		end)
		expect(not ok, "accepted a non-HTTPS URL")
	end)

	check("httpRequest rejects unbounded timeouts", function()
		local ok = pcall(function()
			love.system.httpRequest("https://example.invalid/", "GET", nil, nil, nil, 121)
		end)
		expect(not ok, "accepted a timeout above the limit")
	end)

	check("httpRequest rejects signed-header injection", function()
		local ok = pcall(function()
			love.system.httpRequest(
				"https://example.invalid/",
				"GET",
				{ "X-Signature", "valid\r\nX-Injected: yes" }
			)
		end)
		expect(not ok, "accepted a header containing a newline")
	end)

	check("httpRequest returns HTTP error status and body", function()
		local response = love.system.httpRequest(
			"https://api.github.com/this-route-should-not-exist",
			"GET",
			nil,
			nil,
			"love-nx-test",
			15
		)
		local status, body = response:match("^STATUS (%d%d%d)\n(.*)$")
		expect(status == "404", "unexpected response: " .. tostring(response))
		expect(type(body) == "string", "missing error response body")
	end)

	check("httpRequest returns transport error envelope", function()
		local response = love.system.httpRequest(
			"https://192.0.2.1/",
			"GET",
			nil,
			nil,
			"love-nx-test",
			5
		)
		expect(type(response) == "string" and response:match("^ERROR .+\n$"),
			"unexpected transport response: " .. tostring(response))
	end)

	check("httpDownload rejects path traversal", function()
		local ok = pcall(function()
			love.system.httpDownload("https://example.invalid/", "../escape.txt")
		end)
		expect(not ok, "accepted a parent-directory path")
	end)

	check("httpDownload preserves destination on HTTP error", function()
		local path = "/net-test-preserve.txt"
		local sentinel = "existing save"
		expect(love.filesystem.write(path, sentinel), "could not create test file")
		local ok = love.system.httpDownload(
			"https://api.github.com/this-route-should-not-exist",
			path
		)
		expect(ok == false, "unexpectedly accepted an HTTP error")
		expect(love.filesystem.read(path) == sentinel, "failed download replaced the existing file")
		love.filesystem.remove(path)
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

	check("love.thread + Channel (R5 report-only)", function()
		expect(love.thread and love.thread.newThread, "love.thread missing")
		-- Separate channels so the main thread cannot race-pop the input value
		-- before the worker (that race made v nil and love.threaderror blue-screen).
		local inp = love.thread.getChannel("net-test-in")
		local out = love.thread.getChannel("net-test-out")
		expect(inp and out, "getChannel failed")
		while inp:pop() ~= nil do end
		while out:pop() ~= nil do end
		local code = [[
			local inp = love.thread.getChannel("net-test-in")
			local out = love.thread.getChannel("net-test-out")
			local v = inp:demand()
			out:push(v * 2)
		]]
		local thread = love.thread.newThread(code)
		expect(thread, "newThread failed")
		local started = thread:start()
		inp:push(21)
		local deadline = os.clock() + 5
		local got
		while os.clock() < deadline do
			got = out:pop()
			if got ~= nil then break end
		end
		local terr = thread.getError and thread:getError() or nil
		local running = thread.isRunning and thread:isRunning() or nil
		log(string.format(
			"  thread diag: started=%s got=%s err=%s running=%s",
			tostring(started), tostring(got), tostring(terr), tostring(running)
		))
		expect(got == 42, "channel round-trip gave " .. tostring(got)
			.. " err=" .. tostring(terr) .. " running=" .. tostring(running))
	end)

	if PC_ENET_HOLD then
		local enet = require("enet")
		local ok, host = pcall(enet.host_create, ":7777", 32, 2)
		if ok and host then
			live_enet_host = host
			log("  enet live host on :7777 for pc_enet_peer.py client <switch-ip>")
		else
			log("  enet live host failed: " .. tostring(host))
		end
	end

	done = true
end

function love.load()
	-- Default love.threaderror calls error() and replaces the acceptance screen.
	-- R5 is report-only: log and keep the results table visible.
	function love.threaderror(t, err)
		log("  threaderror: " .. tostring(t) .. " — " .. tostring(err))
	end
	runChecks()
end

function love.update(_dt)
	if not live_enet_host then return end
	local ev = live_enet_host:service(0)
	while ev do
		if ev.type == "connect" then
			log("  enet live: connect")
			ev.peer:send("hello-from-switch", 0, "reliable")
		elseif ev.type == "receive" then
			log("  enet live: " .. tostring(ev.data))
			ev.peer:send("ack:" .. ev.data, ev.channel, "reliable")
		elseif ev.type == "disconnect" then
			log("  enet live: disconnect")
		end
		ev = live_enet_host:service(0)
	end
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
