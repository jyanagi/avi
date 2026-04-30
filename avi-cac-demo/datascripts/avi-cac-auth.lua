-- Avi / NSX ALB HTTP Request Event Script
-- CAC-style certificate validation and identity header assertion

local UPN_DOMAIN = "demo.lab"

local function deny(code, msg)
  avi.http.response(code, { ["Content-Type"] = "text/plain" }, msg)
end

local function strip_headers()
  avi.http.remove_header("X-Remote-User")
  avi.http.remove_header("X-Avi-Client-Cert-Auth")
  avi.http.remove_header("X-Avi-Client-Cert-Subject")
  avi.http.remove_header("X-Avi-Client-Cert-Issuer")
  avi.http.remove_header("X-Avi-Client-Cert-CN")
  avi.http.remove_header("X-Avi-Client-Cert-EDIPI")
end

local function extract_cn(subject)
  if subject == nil then return "" end

  local cn = string.match(subject, "CN=([^,]+)")
  if cn == nil then
    cn = string.match(subject, "/CN=([^/]+)")
  end

  return cn or ""
end

local function extract_edipi(cn)
  if cn == nil then return "" end
  return string.match(cn, "(%d+)$") or ""
end

local function cn_to_upn(cn)
  -- Example CN: DOE.JANE.A.1234567890
  -- Output: jane.doe@demo.lab

  local last, first = string.match(cn, "^([A-Za-z]+)%.([A-Za-z]+)%.")
  if last == nil or first == nil then
    return ""
  end

  return string.lower(first .. "." .. last .. "@" .. UPN_DOMAIN)
end

strip_headers()

local cert_status = avi.ssl.check_client_cert_validity()

-- For this Avi build, 1 = valid client certificate
if cert_status ~= 1 then
  deny(403, "Client certificate required or invalid. Status=" .. tostring(cert_status))
  return
end

local subject = avi.ssl.client_cert(avi.CLIENT_CERT_SUBJECT) or ""
local issuer  = avi.ssl.client_cert(avi.CLIENT_CERT_ISSUER) or ""

local cn = extract_cn(subject)
local edipi = extract_edipi(cn)
local upn = cn_to_upn(cn)

if cn == "" then
  deny(403, "Unable to extract CN from certificate subject. Subject=" .. subject)
  return
end

if edipi == "" then
  deny(403, "Unable to extract EDIPI from certificate CN. CN=" .. cn)
  return
end

if upn == "" then
  deny(403, "Unable to derive UPN from certificate CN. CN=" .. cn)
  return
end

avi.http.add_header("X-Avi-Client-Cert-Auth", "SUCCESS")
avi.http.add_header("X-Remote-User", upn)
avi.http.add_header("X-Avi-Client-Cert-Subject", subject)
avi.http.add_header("X-Avi-Client-Cert-Issuer", issuer)
avi.http.add_header("X-Avi-Client-Cert-CN", cn)
avi.http.add_header("X-Avi-Client-Cert-EDIPI", edipi)