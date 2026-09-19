local M = {}

local function error_response(id, code, message, data)
  return {
    id = id,
    error = {
      code = code,
      message = message,
      data = data,
    },
  }
end

function M.new(options)
  options = options or {}
  local server = {
    version = options.version or 1,
    capabilities = vim.deepcopy(options.capabilities or {}),
    handlers = options.handlers or {},
    revision = 0,
    subscribers = {},
  }

  function server:on_event(callback)
    assert(type(callback) == "function", "CurrantGit RPC event subscriber must be a function")
    self.subscribers[#self.subscribers + 1] = callback
    return function()
      for index, subscriber in ipairs(self.subscribers) do
        if subscriber == callback then
          table.remove(self.subscribers, index)
          return
        end
      end
    end
  end

  function server:emit(event, payload)
    local message = {
      event = event,
      revision = self.revision,
      payload = payload,
    }
    for _, subscriber in ipairs(self.subscribers) do
      subscriber(message)
    end
    return message
  end

  function server:request(request)
    if type(request) ~= "table" then
      return error_response(nil, "invalid_request", "request must be a table")
    end
    if request.id == nil then
      return error_response(nil, "invalid_request", "request needs an id")
    end
    if type(request.method) ~= "string" or request.method == "" then
      return error_response(request.id, "invalid_request", "request needs a method")
    end
    if request.params ~= nil and type(request.params) ~= "table" then
      return error_response(request.id, "invalid_params", "params must be a table")
    end
    if request.method == "rpc.capabilities" then
      return {
        id = request.id,
        result = {
          version = self.version,
          capabilities = vim.deepcopy(self.capabilities),
          revision = self.revision,
        },
      }
    end
    local handler = self.handlers[request.method]
    if type(handler) ~= "function" then
      return error_response(request.id, "method_not_found", "unknown method: " .. request.method)
    end
    local ok, result = pcall(handler, request.params or {}, request)
    if not ok then
      return error_response(request.id, "handler_error", tostring(result))
    end
    self.revision = self.revision + 1
    return {
      id = request.id,
      result = {
        value = result,
        revision = self.revision,
      },
    }
  end

  return server
end

return M
