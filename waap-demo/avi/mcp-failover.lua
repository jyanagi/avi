-- MCP-Failover DataScript (HTTP request event)
-- Health-aware session pinning: pin to the mapped server if it is healthy,
-- otherwise remove the stale mapping and let the pool pick a healthy member.
-- POOL_NAME must match the pool created by configure-avi.py.

local POOL = "AI-MCP-L7-Vs-Pool"

local sid = avi.http.get_header("mcp-session-id")
if sid == nil or sid == "" then
  -- no session yet: normal pool selection, mapping is recorded on response
  return
end

local mapped = avi.vs.table_lookup(sid)
if mapped ~= nil then
  local ip, port = string.match(mapped, "([^,]+),([^,]+)")
  if ip ~= nil and port ~= nil then
    ip = string.gsub(ip, "^::ffff:", "")
    local status = avi.pool.get_server_status(POOL, ip, tonumber(port))
    if status == 1 then
      avi.pool.select(POOL, ip, tonumber(port))   -- healthy: pin
      return
    else
      avi.vs.table_remove(sid)                     -- unhealthy: drop stale map
    end
  end
end
avi.pool.select(POOL)                              -- fall back to healthy member
