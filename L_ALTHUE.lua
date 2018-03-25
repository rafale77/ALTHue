-- // This program is free software: you can redistribute it and/or modify
-- // it under the condition that it is for private or home useage and
-- // this whole comment is reproduced in the source code file.
-- // Commercial utilisation is not authorized without the appropriate
-- // written agreement from amg0 / alexis . mermet @ gmail . com
-- // This program is distributed in the hope that it will be useful,
-- // but WITHOUT ANY WARRANTY; without even the implied warranty of
-- // MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE .
local MSG_CLASS		= "ALTHUE"
local ALTHUE_SERVICE	= "urn:upnp-org:serviceId:althue1"
local devicetype	= "urn:schemas-upnp-org:device:althue:1"
local this_device	= nil
local DEBUG_MODE	= false -- controlled by UPNP action
local version		= "v0.01"
local UI7_JSON_FILE = "D_ALTHUE_UI7.json"
local DEFAULT_REFRESH = 30
local NAME_PREFIX	= "Hue "	-- trailing space needed
local hostname		= ""

local json = require("dkjson")
local mime = require('mime')
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
-- local lom = require("lxp.lom") -- http://matthewwild.co.uk/projects/luaexpat/lom.html
-- local xpath = require("xpath")

-- altid is the object ID ( like the relay ID ) on the ALTHUE server
local childmap = {
  ["SONDE%s"] = {
	devtype="urn:schemas-micasaverde-com:device:TemperatureSensor:1",
	devfile="D_TemperatureSensor1.xml",
	name="SONDE %s",
	map="TempSensors" -- user choice in a CSV string 1 to 8 ex:	 2,3
  },
  ["ad%s"] = {
	devtype="urn:schemas-micasaverde-com:device:GenericSensor:1",
	devfile="D_GenericSensor1.xml",
	name="ANALOG %s",
	map="AnalogInputs" -- user choice in a CSV string 1 to 8 ex:  2,3
  },
  ["rl%s"] = {
	devtype="urn:schemas-upnp-org:device:BinaryLight:1",
	devfile="D_BinaryLight1.xml",
	name="RELAIS %s",
	map={1,2} -- hard coded dev 1 and 2
  },
  ["rl1w%s"] = {
	devtype="urn:schemas-upnp-org:device:BinaryLight:1",
	devfile="D_BinaryLight1.xml",
	name="RELAIS 1W %s",
	map="Relais1W"	-- user choice in a CSV string 1 to 8 ex:  2,3
  },
  ["in%s"] = {
	devtype="urn:schemas-upnp-org:device:BinaryLight:1",
	devfile="D_BinaryLight1.xml",
	name="ENTREE %s",
	map={1,2} -- hard coded dev 1 and 2
  },
  ["vs%s"] = {
	devtype="urn:schemas-upnp-org:device:BinaryLight:1",
	devfile="D_BinaryLight1.xml",
	name="SWITCH %s",
	map="VirtualSwitches" -- user choice in a CSV string 1 to 8 ex:	 2,3
  },
  ["tic%s"] = {
	devtype="urn:schemas-micasaverde-com:device:PowerMeter:1",
	devfile="D_PowerMeter1.xml",
	name="TIC %s",
	map={1,2} -- hard coded dev 1 and 2
  },
  ["pa%s"] = {
	devtype="urn:schemas-micasaverde-com:device:PowerMeter:1",
	devfile="D_PowerMeter1.xml",
	name="PINCE %s",
	map="AnalogClamps" -- user choice in a CSV string 1 to 8 ex:  2,3
  },
  ["pls%s"] = {
	devtype="urn:schemas-micasaverde-com:device:PowerMeter:1",
	devfile="D_PowerMeter1.xml",
	name="PULSE %s",
	map="PulseCounters" -- user choice in a CSV string 1 to 8 ex:  2,3
  }
}

------------------------------------------------
-- Debug --
------------------------------------------------
function log(text, level)
  luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

function debug(text)
  if (DEBUG_MODE) then
	log("debug: " .. text)
  end
end

function warning(stuff)
  log("warning: " .. stuff, 2)
end

function error(stuff)
  log("error: " .. stuff, 1)
end

local function isempty(s)
  return s == nil or s == ""
end

local function extractTagValue(xml)
  local pattern = "<(.*)>(.*)</.*>"
  local resa,resb = string.match( xml, pattern)
  return resa,resb
end

local function findTHISDevice()
  for k,v in pairs(luup.devices) do
	if( v.device_type == devicetype ) then
	  return k
	end
  end
  return -1
end

------------------------------------------------
-- Device Properties Utils
------------------------------------------------
function getSetVariable(serviceId, name, deviceId, default)
  local curValue = luup.variable_get(serviceId, name, deviceId)
  if (curValue == nil) then
	curValue = default
	luup.variable_set(serviceId, name, curValue, deviceId)
  end
  return curValue
end

function getSetVariableIfEmpty(serviceId, name, deviceId, default)
  local curValue = luup.variable_get(serviceId, name, deviceId)
  if (curValue == nil) or (curValue:trim() == "") then
	curValue = default
	luup.variable_set(serviceId, name, curValue, deviceId)
  end
  return curValue
end

function setVariableIfChanged(serviceId, name, value, deviceId)
  debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, value, deviceId))
  local curValue = luup.variable_get(serviceId, name, tonumber(deviceId)) or ""
  value = value or ""
  if (tostring(curValue)~=tostring(value)) then
	luup.variable_set(serviceId, name, value, tonumber(deviceId))
  end
end

function setAttrIfChanged(name, value, deviceId)
  debug(string.format("setAttrIfChanged(%s,%s,%s)",name, value, deviceId))
  local curValue = luup.attr_get(name, deviceId)
  if ((value ~= curValue) or (curValue == nil)) then
	luup.attr_set(name, value, deviceId)
	return true
  end
  return value
end

local function getIP()
  -- local stdout = io.popen("GetNetworkState.sh ip_wan")
  -- local ip = stdout:read("*a")
  -- stdout:close()
  -- return ip
  local mySocket = socket.udp ()
  mySocket:setpeername ("42.42.42.42", "424242")  -- arbitrary IP/PORT
  local ip = mySocket:getsockname ()
  mySocket: close()
  return ip or "127.0.0.1"
end

------------------------------------------------
-- Tasks
------------------------------------------------
local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

--
-- Has to be "non-local" in order for MiOS to call it :(
--
local function task(text, mode)
  if (mode == TASK_ERROR_PERM)
  then
	error(text)
  elseif (mode ~= TASK_SUCCESS)
  then
	warning(text)
  else
	log(text)
  end
  if (mode == TASK_ERROR_PERM)
  then
	taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
  else
	taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

	-- Clear the previous error, since they're all transient
	if (mode ~= TASK_SUCCESS)
	then
	  luup.call_delay("clearTask", 15, "", false)
	end
  end
end

function clearTask()
  task("Clearing...", TASK_SUCCESS)
end

function UserMessage(text, mode)
  mode = (mode or TASK_ERROR)
  task(text,mode)
end

------------------------------------------------
-- LUA Utils
------------------------------------------------
local function Split(str, delim, maxNb)
  -- Eliminate bad cases...
  if string.find(str, delim) == nil then
	return { str }
  end
  if maxNb == nil or maxNb < 1 then
	maxNb = 0	 -- No limit
  end
  local result = {}
  local pat = "(.-)" .. delim .. "()"
  local nb = 0
  local lastPos
  for part, pos in string.gmatch(str, pat) do
	nb = nb + 1
	result[nb] = part
	lastPos = pos
	if nb == maxNb then break end
  end
  -- Handle the last field
  if nb ~= maxNb then
	result[nb + 1] = string.sub(str, lastPos)
  end
  return result
end

function string:split(sep) -- from http://lua-users.org/wiki/SplitJoin	 : changed as consecutive delimeters was not returning empty strings
  return Split(self, sep)
  -- local sep, fields = sep or ":", {}
  -- local pattern = string.format("([^%s]+)", sep)
  -- self:gsub(pattern, function(c) fields[#fields+1] = c end)
  -- return fields
end


function string:template(variables)
  return (self:gsub('@(.-)@',
	function (key)
	  return tostring(variables[key] or '')
	end))
end

function string:trim()
  return self:match "^%s*(.-)%s*$"
end

------------------------------------------------
-- VERA Device Utils
------------------------------------------------

local function tablelength(T)
  local count = 0
  if (T~=nil) then
  for _ in pairs(T) do count = count + 1 end
  end
  return count
end

local function getParent(lul_device)
  return luup.devices[lul_device].device_num_parent
end

local function getAltID(lul_device)
  return luup.devices[lul_device].id
end

-----------------------------------
-- from a altid, find a child device
-- returns 2 values
-- a) the index === the device ID
-- b) the device itself luup.devices[id]
-----------------------------------
local function findChild( lul_parent, altid )
  -- debug(string.format("findChild(%s,%s)",lul_parent,altid))
  for k,v in pairs(luup.devices) do
	if( getParent(k)==lul_parent) then
	  if( v.id==altid) then
		return k,v
	  end
	end
  end
  return nil,nil
end

local function getParent(lul_device)
  return luup.devices[lul_device].device_num_parent
end

local function getRoot(lul_device)
  while( getParent(lul_device)>0 ) do
	lul_device = getParent(lul_device)
  end
  return lul_device
end
------------------------------------------------
-- Communication TO ALTHUE system
------------------------------------------------

local function myHttpGet(dst_ipaddr,dst_port,uri,timeout,credentials)
  debug( string.format("myHttpGet(%s,%s,%s,%s,%s)",dst_ipaddr,dst_port,uri,timeout,credentials) )
  local a,b,s
  local result = {}
  local command = string.format("GET %s HTTP/1.1\r\n",uri)
  dst_port = dst_port or 80
  timeout = timeout or 5

  local auth = ""
  if (isempty(credentials) == false) then
	auth = "Authorization: Basic ".. credentials .. "\r\n"
  end

  local headers = [[
Host: %s
User-Agent: LuaSocket 3.0-rc1
Accept: */*
TE: trailers
Connection: close, TE
]]
  headers = string.format(headers,dst_ipaddr)
  headers = headers:gsub("\n","\r\n")

  local tcp,b = socket.tcp()
  if (tcp==nil) then
	  error( string.format("Socket tcp creation failed. err:%s",b or ""))
  else
	tcp:settimeout( timeout )
	s,b = tcp:connect (dst_ipaddr, dst_port) -- this should be server IP
	if (s==nil) then
	  error( string.format("Socket connect to %s:%s failed, err:%s",dst_ipaddr,dst_port,b or ""))
	else
	  tcp:settimeout(timeout)
	  a,b  = tcp:send(command..auth..headers)
	  if (a==nil) then
		error( string.format("Socket send failed, err=%s",b or ""))
	  else
		a,b = tcp:receive('*l')
		debug(string.format("Socket received: %s",a or ""))
		-- should be HTTP/1.1 200 OK
		if (a==nil) or (a~="HTTP/1.1 200 OK") then
		  error( string.format("Socket received failed, err=%s",b or ""))
		else
		  -- HEADERS
		  repeat
			a,b,s = tcp:receive('*l')
			if (a~=nil) then
			  debug(string.format("header received: %s",a))
			else
			  debug(string.format("b=%s s=%s",b,s))
			end
		  until #a == 0 -- empty line received

		  -- BODY
		  repeat
			a,b,s = tcp:receive('*l')
			if (a~=nil) then
			  table.insert(result, a)
			elseif (s~=nil) then
			  -- strange but apparently we receive a socket "close" while there is still some data in 's'
			  table.insert(result, s)
			end
		  until b	-- that is, until "timeout" or "closed"

		  tcp:close()
		  return table.concat(result)
		end
	  end
	  tcp:close()
	end
  end
  return nil,b
end

local function ALTHueHttpCall(lul_device,cmd,data)
  lul_device = tonumber(lul_device)
  local lul_root = getRoot(lul_device)
  data = data  or ""
  debug(string.format("ALTHueHttpCall(%d,%s,%s) , root:%s",lul_device,cmd,data,lul_root))

  -- get parameter from root device
  local credentials= getSetVariable(ALTHUE_SERVICE,"Credentials", lul_root, "")
  local ip_address = luup.attr_get ('ip', lul_root )

  if (isempty(ip_address)) then
	warning(string.format("IPADDR is not initialized. ipaddr=%s",ip_address))
	return nil
  end
  if (credentials=="") then
	warning("Missing credentials for ALTHue device :"..lul_device)
	return nil
  end

  -- local uri = string.format ("/%s?%s", cmd,data)
  -- local txt,msg = myHttpGet(ip_address,80,uri,5,credentials)
  local txt = nil
  local msg = "todo"

  if (txt==nil) then
	-- failure
	setVariableIfChanged(ALTHUE_SERVICE, "IconCode", 0, lul_device)
	debug(string.format("failure=> Error Message:%s",msg or ""))
	return nil
  end
  -- success
  debug(string.format("myHttpGet returns:%s",txt))
  setVariableIfChanged(ALTHUE_SERVICE, "IconCode", 100, lul_device)
  return txt
end

------------------------------------------------------------------------------------------------
-- Http handlers : Communication FROM ALTUI
-- http://192.168.1.5:3480/data_request?id=lr_ALTHUE_Handler&command=xxx
-- recommended settings in ALTUI: PATH = /data_request?id=lr_ALTHUE_Handler&mac=$M&deviceID=114
------------------------------------------------------------------------------------------------
function switch( command, actiontable)
  -- check if it is in the table, otherwise call default
  if ( actiontable[command]~=nil ) then
	return actiontable[command]
  end
  warning("ALTHUE_Handler:Unknown command received:"..command.." was called. Default function")
  return actiontable["default"]
end

function myALTHUE_Handler(lul_request, lul_parameters, lul_outputformat)
  debug('myALTHUE_Handler: request is: '..tostring(lul_request))
  debug('myALTHUE_Handler: parameters is: '..json.encode(lul_parameters))
  local lul_html = "";	-- empty return by default
  local mime_type = "";
  if (hostname=="") then
	hostname = getIP()
	debug("now hostname="..hostname)
  end

  -- find a parameter called "command"
  if ( lul_parameters["command"] ~= nil ) then
	command =lul_parameters["command"]
  else
	  debug("ALTHUE_Handler:no command specified, taking default")
	command ="default"
  end

  local deviceID = this_device or tonumber(lul_parameters["DeviceNum"] or findTHISDevice() )

  -- switch table
  local action = {

	  ["default"] =
	  function(params)
		return "default handler / not successful", "text/plain"
	  end
  }
  -- actual call
  lul_html , mime_type = switch(command,action)(lul_parameters)
  if (command ~= "home") and (command ~= "oscommand") then
	debug(string.format("lul_html:%s",lul_html or ""))
  end
  return (lul_html or "") , mime_type
end

------------------------------------------------
-- STARTUP Sequence
------------------------------------------------

function UserSetPowerTarget(lul_device,newTargetValue)
  lul_device = tonumber(lul_device)
  debug(string.format("UserSetPowerTarget(%s,%s)",lul_device,newTargetValue))
  local status = luup.variable_get("urn:upnp-org:serviceId:SwitchPower1", "Status", lul_device)
  if (status ~= newTargetValue) then
	local val = "ON";
	if (newTargetValue=="0") then
	  val = "OFF";
	end
	
	
	-- altid is the relay ID on the ALTHUE
	-- local childid = luup.devices[lul_device].id;
	-- prefix rl1W should be replaced by rl
	-- childid = string.gsub(childid, "1w", "")
	-- luup.variable_set("urn:upnp-org:serviceId:SwitchPower1", "Status", newTargetValue, lul_device)
	-- local xmldata = ALTHueHttpCall(lul_device,"RL.cgx",childid.."="..val)
  else
	debug(string.format("UserSetPowerTarget(%s,%s) - same status, ignoring",lul_device,newTargetValue))
  end
end

function UserToggleState(lul_device)
  debug(string.format("UserToggleState(%s)",lul_device))
  local status = luup.variable_get("urn:upnp-org:serviceId:SwitchPower1", "Status", lul_device)
  status = 1-tonumber(status)
  UserSetPowerTarget(lul_device,tostring(status))
end

function getCurrentTemperature(lul_device)
  lul_device = tonumber(lul_device)
  debug(string.format("getCurrentTemperature(%d)",lul_device))
  return luup.variable_get("urn:upnp-org:serviceId:TemperatureSensor1", "CurrentTemperature", lul_device)
end

local function loadALTHueData(lul_device,xmldata)
  debug(string.format("loadALTHueData(%s) xml=%s",lul_device,xmldata))
  return true
end

function refreshEngineCB(lul_device,norefresh)
  norefresh = norefresh or false
  debug(string.format("refreshEngineCB(%s,%s)",lul_device,tostring(norefresh)))
  lul_device = tonumber(lul_device)
  local period= getSetVariable(ALTHUE_SERVICE, "RefreshPeriod", lul_device, DEFAULT_REFRESH)

  local xmldata = nil --ALTHueHttpCall(lul_device,"")
  if (xmldata ~= nil) then
	loadALTHueData(lul_device,xmldata)
  else
	UserMessage(string.format("missing ip addr or credentials for device "..lul_device),TASK_ERROR_PERM)
  end

  debug(string.format("programming next refreshEngineCB(%s) in %s sec",lul_device,period))
  if (norefresh==false) then
	luup.call_delay("refreshEngineCB",period,tostring(lul_device))
  end
end

------------------------------------------------
-- UPNP actions Sequence
------------------------------------------------
local function setDebugMode(lul_device,newDebugMode)
  lul_device = tonumber(lul_device)
  newDebugMode = tonumber(newDebugMode) or 0
  debug(string.format("setDebugMode(%d,%d)",lul_device,newDebugMode))
  luup.variable_set(ALTHUE_SERVICE, "Debug", newDebugMode, lul_device)
  if (newDebugMode==1) then
	DEBUG_MODE=true
  else
	DEBUG_MODE=false
  end
end

local function refreshData(lul_device)
  lul_device = tonumber(lul_device)
  debug(string.format("refreshData(%d)",lul_device))
  refreshEngineCB(lul_device,true)
end

local function startEngine(lul_device)
  debug(string.format("startEngine(%s)",lul_device))
  lul_device = tonumber(lul_device)

  local data = ALTHueHttpCall(lul_device,"")
  -- local xmldata = ALTHueHttpCall(lul_device,"xml/zones/zonesDescription16IP.xml")
  if (data ~= nil) then
	local period= getSetVariable(ALTHUE_SERVICE, "RefreshPeriod", lul_device, DEFAULT_REFRESH)
	luup.call_delay("refreshEngineCB",period,tostring(lul_device))
	return loadALTHueData(lul_device,data)
  else
	UserMessage(string.format("missing ip addr or credentials for device "..lul_device),TASK_ERROR_PERM)
  end
  return true
end

function startupDeferred(lul_device)
  lul_device = tonumber(lul_device)
  log("startupDeferred, called on behalf of device:"..lul_device)

  local debugmode = getSetVariable(ALTHUE_SERVICE, "Debug", lul_device, "0")
  local oldversion = getSetVariable(ALTHUE_SERVICE, "Version", lul_device, "")
  local period= getSetVariable(ALTHUE_SERVICE, "RefreshPeriod", lul_device, DEFAULT_REFRESH)
  local credentials	 = getSetVariable(ALTHUE_SERVICE, "Credentials", lul_device, "")
  local NamePrefix = getSetVariable(ALTHUE_SERVICE, "NamePrefix", lul_device, NAME_PREFIX)
  local iconCode = getSetVariable(ALTHUE_SERVICE,"IconCode", lul_device, "0")
  -- local ipaddr = luup.attr_get ('ip', lul_device )

  if (debugmode=="1") then
	DEBUG_MODE = true
	UserMessage("Enabling debug mode for device:"..lul_device,TASK_BUSY)
  end
  local major,minor = 0,0
  local tbl={}

  if (oldversion~=nil) then
	if (oldversion ~= "") then
	  major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
	  major,minor = tonumber(major),tonumber(minor)
	  debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)

	  newmajor,newminor = string.match(version,"v(%d+)%.(%d+)")
	  newmajor,newminor = tonumber(newmajor),tonumber(newminor)
	  debug ("Device's New Version is major:"..newmajor.." minor:"..newminor)

	  -- force the default in case of upgrade
	  if ( (newmajor>major) or ( (newmajor==major) and (newminor>minor) ) ) then
		log ("Version upgrade => Reseting Plugin config to default and FTP uploading the *.CGX file on the ALTHUE server")

	  end
	else
	  log ("New installation")
	end
	luup.variable_set(ALTHUE_SERVICE, "Version", version, lul_device)
  end

  -- start handlers
  -- createChildren(lul_device)
  -- start engine
  local success = false
  success = startEngine(lul_device)

  -- NOTHING to start
  if( luup.version_branch == 1 and luup.version_major == 7) then
	if (success == true) then
	  luup.set_failure(0,lul_device)  -- should be 0 in UI7
	else
	  luup.set_failure(1,lul_device)  -- should be 0 in UI7
	end
  else
	luup.set_failure(false,lul_device)	-- should be 0 in UI7
  end

  log("startup completed")
end

------------------------------------------------
-- Check UI7
------------------------------------------------
local function checkVersion(lul_device)
  local ui7Check = luup.variable_get(ALTHUE_SERVICE, "UI7Check", lul_device) or ""
  if ui7Check == "" then
	luup.variable_set(ALTHUE_SERVICE, "UI7Check", "false", lul_device)
	ui7Check = "false"
  end
  if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
	luup.variable_set(ALTHUE_SERVICE, "UI7Check", "true", lul_device)
	luup.attr_set("device_json", UI7_JSON_FILE, lul_device)
	luup.reload()
  end
end

function initstatus(lul_device)
  lul_device = tonumber(lul_device)
  this_device = lul_device
  log("initstatus("..lul_device..") starting version: "..version)
  checkVersion(lul_device)
  hostname = getIP()
  local delay = 1	-- delaying first refresh by x seconds
  debug("initstatus("..lul_device..") startup for Root device, delay:"..delay)
  luup.call_delay("startupDeferred", delay, tostring(lul_device))
end

-- do not delete, last line must be a CR according to MCV wiki page
