#!/usr/bin/env lua

local Stream = require 'Stream'
local json = require 'cjson'

local M = require 'posix.sys.socket'
local unistd = require 'posix.unistd'
local poll = require 'posix.poll'

-- 5.1 shim
local struct = require 'struct'

-- local class = require 'class'
local function class(init)
  local c = {}    -- a new class instance

  -- the class will be the metatable for all its objects,
  -- and they will look up their methods in it.
  c.__index = c

  -- expose a constructor which can be called by <classname>(<args>)
  local mt = {}
  c.__new = function()
    local obj = {}
    setmetatable(obj, c)
    return obj
  end
  mt.__call = function(class_tbl, ...)
    local n = c.__new()
    c.init(n, ...)
    return n
  end
  c.init = init
  c.isA = function(self)
    return getmetatable(self) == c
  end
  setmetatable(c, mt)
  return c
end

local Sway = class()

local function guessSwaysock()
  local sockpath = os.getenv("SWAYSOCK")
  if not sockpath then
    -- TODO change this to a more native solution.
    local cmd = io.popen("ls -1t /run/user/*/sway-ipc.*.sock | tail -n1")
    sockpath = cmd:read("*a"):match("%S+")
    cmd:close()
  end
  return sockpath
end

function Sway.connect(SWAYSOCK)
  SWAYSOCK = SWAYSOCK or guessSwaysock()
  local self = Sway.__new()

  self.socket = assert(M.socket(M.AF_UNIX, M.SOCK_STREAM, 0))
  M.connect(self.socket, {family=M.AF_UNIX, path=SWAYSOCK})

  return self
end

function Sway:close()
  unistd.close(self.socket)
end

function Sway:__gc()
  if self.socket then
    self:close()
  end
end

Sway.init = Sway.connect

local SWAY_COMMAND = {
  RUN_COMMAND = 0,
  GET_WORKSPACES = 1,
  SUBSCRIBE = 2,
  GET_OUTPUTS = 3,
  GET_TREE = 4,
  GET_MARKS = 5,
  GET_BAR_CONFIG = 6,
  GET_VERSION = 7,
  GET_BINDING_MODES = 8,
  GET_CONFIG = 9,
  SEND_TICK = 10,
}

local SWAY_EVENTS = {
  workspace = 0x80000000,
  mode = 0x80000002,
  window = 0x80000003,
  barconfig_update = 0x80000004,
  binding = 0x80000005,
  shutdown = 0x80000006,
  tick = 0x80000007,
  bar_status_update = 0x80000014,
}

Sway.COMMANDS = SWAY_COMMAND
Sway.EVENTS = SWAY_EVENTS

function Sway.formatIpc(command_type, payload)
  -- return "i3-ipc"..string.pack("=i4=i4", #payload, command_type)..payload
  return "i3-ipc"..struct.pack("i4i4", #payload, command_type)..payload
end

function Sway:send(command)
  return M.send(self.socket, command)
end

function Sway:tryReceive()
  local start_string = M.recv(self.socket, #"i3-ipc")
  if start_string == nil or #start_string == 0 then
    return nil
  end
  assert(start_string == "i3-ipc")
  -- local payload_length = string.unpack("=i4", M.recv(self.socket, 4))
  -- local payload_type = string.unpack("=I4", M.recv(self.socket, 4))
  local payload_length = struct.unpack("i4", M.recv(self.socket, 4))
  local payload_type = struct.unpack("I4", M.recv(self.socket, 4))
  local payload = M.recv(self.socket, payload_length)
  return json.decode(payload), payload_type
end

function Sway:rawIpc(command)
  self:send(command)
  return self:tryReceive()
end

function Sway:ipc(command_type, payload)
  return self:rawIpc(Sway.formatIpc(command_type, payload))
end

function Sway:jsonIpc(command_type, payload)
  return self:ipc(command_type, json.encode(payload))
end

function Sway:msg(...)
  local command = table.concat({...}, ";")
  return self:ipc(SWAY_COMMAND.RUN_COMMAND, command)
end

function Sway.formatCriteria(criteria)
  local result = {}
  for k, v in pairs(criteria) do
    if type(v) == 'number' then
      v = math.floor(v)
    end
    table.insert(result, string.format("%s=%q", k, v) )
  end
  return "["..table.concat(result, " ").."]"
end

function Sway:criteriaMsg(criteria, commands)
  local command = Sway.formatCriteria(criteria).." "..table.concat(commands, ",")
  return self:ipc(SWAY_COMMAND.RUN_COMMAND, command)
end

function Sway.eventName(number)
  for k, v in pairs(SWAY_EVENTS) do
    if v == number then
      return k
    end
  end
end

-- Pass through cjson's null for convenience
Sway.null = json.null

function Sway:getTree()
  return self:ipc(SWAY_COMMAND.GET_TREE, "")
end

function Sway:getOutputs()
  return self:ipc(SWAY_COMMAND.GET_OUTPUTS, "")
end

function Sway:getMarks()
  return self:ipc(SWAY_COMMAND.GET_MARKS, "")
end

function Sway:getConfig()
  return self:ipc(SWAY_COMMAND.GET_CONFIG, "")
end

function Sway:getBindingModes()
  return self:ipc(SWAY_COMMAND.GET_BINDING_MODES, "")
end

function Sway:getInputs()
  return self:ipc(SWAY_COMMAND.GET_INPUTS, "")
end

function Sway:getWorkspaces()
  return self:ipc(SWAY_COMMAND.GET_WORKSPACES, "")
end

function Sway:subscribe(events, timeout)
  assert(events and #events > 0, "must specify events to subscribe to.")
  local filtered_events = {}
  for _, v in ipairs(events) do
    if SWAY_EVENTS[v] then
      table.insert(filtered_events, v)
    end
  end
  assert(#filtered_events > 0, "No valid events found")
  timeout = timeout or 100
  return Stream.fromFunction(function()
    assert(self:jsonIpc(SWAY_COMMAND.SUBSCRIBE, filtered_events).success, "Failed to subscribe")
    while true do
      local ready = poll.rpoll(self.socket, timeout)
      if ready == 1 then
        coroutine.yield(self:tryReceive())
      end
    end
  end)
end

return Sway
