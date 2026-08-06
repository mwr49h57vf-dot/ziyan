-- res 示例：供 Python lua_call 调用
function mul(a, b)
  return (tonumber(a) or 0) * (tonumber(b) or 0)
end

function ping()
  return "pong-lua"
end
