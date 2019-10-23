-- Copyright (C) 2012 Yichun Zhang (agentzh)
-- Copyright (C) 2014 Chang Feng
-- This file is modified version from https://github.com/openresty/lua-resty-mysql
-- The license is under the BSD license.
-- Modified by Cloud Wu (remove bit32 for lua 5.3)

local socketchannel = require "skynet.socketchannel"
local crypt = require "skynet.crypt"


local mathfloor = math.floor
local sub = string.sub
local strgsub = string.gsub
local strformat = string.format
local strbyte = string.byte
local strchar = string.char
local strrep = string.rep
local strunpack = string.unpack
local strpack = string.pack
local sha1= crypt.sha1
local setmetatable = setmetatable
local error = error
local tonumber = tonumber

local _M = { _VERSION = '0.14' }
-- constants

local pow_2_16 = 2^16
local pow_2_24 = 2^24

local STATE_CONNECTED = 1
local STATE_COMMAND_SENT = 2

local COM_QUERY = 0x03
local COM_PING = 0x0e
local COM_STMT_PREPARE = 0x16
local COM_STMT_EXECUTE = 0x17
local COM_STMT_SEND_LONG_DATA = 0x18
local COM_STMT_CLOSE = 0x19
local COM_STMT_RESET = 0x1a
local COM_SET_OPTION = 0x1b
local COM_STMT_FETCH = 0x1c

local CURSOR_TYPE_NO_CURSOR = 0x00
local CURSOR_TYPE_READ_ONLY = 0x01
local CURSOR_TYPE_FOR_UPDATE = 0x02
local CURSOR_TYPE_SCROLLABLE = 0x04

local SERVER_MORE_RESULTS_EXISTS = 8

local mt = { __index = _M }

-- mysql field value type converters
local converters = {}

for i = 0x01, 0x05 do
    -- tiny, short, long, float, double
    converters[i] = tonumber
end
converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal

local function _get_byte1(data, i)
	return strbyte(data,i),i+1
end

local function _get_byte2(data, i)
	return strunpack("<I2",data,i)
end

local function _get_byte3(data, i)
	return strunpack("<I3",data,i)
end

local function _get_byte4(data, i)
	return strunpack("<I4",data,i)
end

local function _get_byte8(data, i)
	return strunpack("<I8",data,i)
end

local function _get_float(data, i)
	return strunpack("<f",data,i)
end

local function _get_double(data, i)
	return strunpack("<d",data,i)
end

local function _set_byte2(n)
    return strpack("<I2", n)
end


local function _set_byte3(n)
    return strpack("<I3", n)
end


local function _set_byte4(n)
    return strpack("<I4", n)
end

local function _set_byte8(n)
    return strpack("<I8", n)
end

local function _set_float(n)
    return strpack("<f", n)
end

local function _set_double(n)
    return strpack("<d", n)
end

local function _from_cstring(data, i)
    return strunpack("z", data, i)
end

local function _dumphex(bytes)
	return strgsub(bytes, ".", function(x) return strformat("%02x ", strbyte(x)) end)
end


local function _compute_token(password, scramble)
    if password == "" then
        return ""
    end
    --_dumphex(scramble)

    local stage1 = sha1(password)
    --print("stage1:", _dumphex(stage1) )
    local stage2 = sha1(stage1)
    local stage3 = sha1(scramble .. stage2)

	local i = 0
	return strgsub(stage3,".",
		function(x)
			i = i + 1
			-- ~ is xor in lua 5.3
			return strchar(strbyte(x) ~ strbyte(stage1, i))
		end)
end

local function _compose_packet(self, req, size)
   self.packet_no = self.packet_no + 1

    local packet = _set_byte3(size) .. strchar(self.packet_no) .. req
    return packet
end

local function _recv_packet(self,sock)


    local data = sock:read( 4)
    if not data then
        return nil, nil, "failed to receive packet header: "
    end


    local len, pos = _get_byte3(data, 1)


    if len == 0 then
        return nil, nil, "empty packet"
    end

    local num = strbyte(data, pos)

    self.packet_no = num

    data = sock:read(len)

    if not data then
        return nil, nil, "failed to read packet content: "
    end


    local field_count = strbyte(data, 1)
    local typ
    if field_count == 0x00 then
        typ = "OK"
    elseif field_count == 0xff then
        typ = "ERR"
    elseif field_count == 0xfe then
        typ = "EOF"
    else
        typ = "DATA"
    end

    return data, typ
end


local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    if not first then
        return nil, pos
    end

    if first >= 0 and first <= 250 then
        return first, pos + 1
    end

    if first == 251 then
        return nil, pos + 1
    end

    if first == 252 then
        pos = pos + 1
        return _get_byte2(data, pos)
    end

    if first == 253 then
        pos = pos + 1
        return _get_byte3(data, pos)
    end

    if first == 254 then
        pos = pos + 1
        return _get_byte8(data, pos)
    end

    return false, pos + 1
end

local function _set_length_coded_bin(n)
    if n<251 then
        return strchar(n)
    end

    if n<pow_2_16 then
        return strchar(0xfc).._set_byte2(n)
    end

    if n<pow_2_24 then
        return strchar(0xfd).._set_byte3(n)
    end

    return strchar(0xfe).._set_byte8(n)
end

local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == nil then
        return nil, pos
    end

    return sub(data, pos, pos + len - 1), pos + len
end


local function _parse_ok_packet(packet)
    local res = {}
    local pos

    res.affected_rows, pos = _from_length_coded_bin(packet, 2)

    res.insert_id, pos = _from_length_coded_bin(packet, pos)

    res.server_status, pos = _get_byte2(packet, pos)

    res.warning_count, pos = _get_byte2(packet, pos)


    local message = sub(packet, pos)
    if message and message ~= "" then
        res.message = message
    end


    return res
end


local function _parse_eof_packet(packet)
    local pos = 2

    local warning_count, pos = _get_byte2(packet, pos)
    local status_flags = _get_byte2(packet, pos)

    return warning_count, status_flags
end


local function _parse_err_packet(packet)
    local errno, pos = _get_byte2(packet, 2)
    local marker = sub(packet, pos, pos)
    local sqlstate
    if marker == '#' then
        -- with sqlstate
        pos = pos + 1
        sqlstate = sub(packet, pos, pos + 5 - 1)
        pos = pos + 5
    end

    local message = sub(packet, pos)
    return errno, message, sqlstate
end


local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)

    local extra
    extra = _from_length_coded_bin(packet, pos)

    return field_count, extra
end


local function _parse_field_packet(data)
    local col = {}
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)


    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)

    pos = pos + 1 -- ignore the filler

    charsetnr, pos = _get_byte2(data, pos)

    length, pos = _get_byte4(data, pos)

    col.type = strbyte(data, pos)

    --[[
    pos = pos + 1

    col.flags, pos = _get_byte2(data, pos)

    col.decimals = strbyte(data, pos)
    pos = pos + 1

    local default = sub(data, pos + 2)
    if default and default ~= "" then
        col.default = default
    end
    --]]

    return col
end


local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row = {}
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type
        local name = col.name

        if value ~= nil then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end

        if compact then
            row[i] = value

        else
            row[name] = value
        end
    end

    return row
end


local function _recv_field_packet(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        return nil, err
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ ~= 'DATA' then
        return nil, "bad field packet type: " .. typ
    end

    -- typ == 'DATA'

    return _parse_field_packet(packet)
end

local function _recv_decode_packet_resp(self)
     return function(sock)
        local packet, typ, err = _recv_packet(self,sock)
        if not packet then
            return false, "failed to receive the result packet"..err
        end

        if typ == 'ERR' then
            local errno, msg, sqlstate = _parse_err_packet(packet)
            return false, strformat("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate)
        end

        if typ == 'EOF' then
            return false, "old pre-4.1 authentication protocol not supported"
        end

        return true, packet
    end
end


local function _mysql_login(self,user,password,database,on_connect)

    return function(sockchannel)
	local dispatch_resp = _recv_decode_packet_resp(self)
        local packet = sockchannel:response( dispatch_resp )

        self.protocol_ver = strbyte(packet)

        local server_ver, pos = _from_cstring(packet, 2)
        if not server_ver then
            error "bad handshake initialization packet: bad server version"
        end

        self._server_ver = server_ver


        local thread_id, pos = _get_byte4(packet, pos)

        local scramble1 = sub(packet, pos, pos + 8 - 1)
        if not scramble1 then
            error "1st part of scramble not found"
        end

        pos = pos + 9 -- skip filler

        -- two lower bytes
        self._server_capabilities, pos = _get_byte2(packet, pos)

        self._server_lang = strbyte(packet, pos)
        pos = pos + 1

        self._server_status, pos = _get_byte2(packet, pos)

        local more_capabilities
        more_capabilities, pos = _get_byte2(packet, pos)

        self._server_capabilities = self._server_capabilities|more_capabilities<<16

        local len = 21 - 8 - 1

        pos = pos + 1 + 10

        local scramble_part2 = sub(packet, pos, pos + len - 1)
        if not scramble_part2 then
            error "2nd part of scramble not found"
        end


        local scramble = scramble1..scramble_part2
        local token = _compute_token(password, scramble)

        local client_flags = 260047;

		local req = strpack("<I4I4c24zs1z",
			client_flags,
			self._max_packet_size,
			strrep("\0", 24),	-- TODO: add support for charset encoding
			user,
			token,
			database)

        local packet_len = #req

        local authpacket=_compose_packet(self,req,packet_len)
        sockchannel:request(authpacket, dispatch_resp)
	if on_connect then
        self.stmts = {}
		on_connect(self)
	end
    end
end

-- 构造ping数据包
local function _compose_ping(self)
    self.packet_no = -1

    local cmd_packet = strchar(COM_PING)
    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_query(self, query)

    self.packet_no = -1

    local cmd_packet = strchar(COM_QUERY) .. query
    local packet_len = 1 + #query

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_stmt_prepare(self, query)
    self.packet_no = -1

    local cmd_packet = strchar(COM_STMT_PREPARE) .. query
    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

--参数字段类型转换
local store_types = {
    number=function(v)
        if mathfloor(v)<v then
            return _set_byte2(0x05),_set_double(v)
        else
            return _set_byte2(0x08),_set_byte8(v)
        end
    end,
    string=function(v)
        return _set_byte2(0x0f),_set_length_coded_bin(#v)..v
    end,
    --bool转换为0,1
    boolean=function(v)
        if v then
            return _set_byte2(0x01),strchar(1)
        else
            return _set_byte2(0x01),strchar(0)
        end
    end,
}

local function _compose_stmt_execute(self,stmt,cursor_type,args)
    local arg_num = #args
    if arg_num~=stmt.param_count then
        error("require stmt.param_count "..stmt.param_count.." get arg_num "..arg_num)
    end

    self.packet_no = -1

    local cmd_packet
    if arg_num>0 then
        local null_count=mathfloor((arg_num+7)/8)

        local f,ts,vs
        local types_buf=""
        local values_buf=""

        for _,v in pairs(args) do
            f= store_types[type(v)]
            if not f then
                error("invalid parameter type",type(v))
            end

            ts,vs = f(v)

            types_buf=types_buf..ts
            values_buf=values_buf..vs
        end

        cmd_packet = strchar(COM_STMT_EXECUTE)
                    .. _set_byte4(stmt.prepare_id)
                    .. strchar(cursor_type)
                    .. _set_byte4(0x01)
                    ..strrep("\0",null_count)
                    ..strchar(0x01)
                    ..types_buf
                    ..values_buf
    else
        cmd_packet = strchar(COM_STMT_EXECUTE)
                    .. _set_byte4(stmt.prepare_id)
                    .. strchar(cursor_type)
                    .. _set_byte4(0x01)
    end

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_stmt_send_long_data(self, prepare_id,arg_id,arg_data)
    local cmd_packet = strchar(COM_STMT_SEND_LONG_DATA)
                    .. _set_byte4(prepare_id)
                    .. _set_byte2(arg_id)
                    .. arg_data

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_stmt_close(self, prepare_id)
    local cmd_packet = strchar(COM_STMT_CLOSE)
                    .. _set_byte4(prepare_id)

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_stmt_reset(self, prepare_id)
    local cmd_packet = strchar(COM_STMT_RESET)
                    .. _set_byte4(prepare_id)

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_set_option(self,option)
    local cmd_packet = strchar(COM_SET_OPTION)
                    .. _set_byte2(option)

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function _compose_stmt_fetch(self,prepare_id,line_num)
    local cmd_packet = strchar(COM_STMT_FETCH)
                    .. _set_byte4(prepare_id)
                    .. _set_byte4(line_num)

    local packet_len = #cmd_packet

    local querypacket = _compose_packet(self, cmd_packet, packet_len)
    return querypacket
end

local function read_result(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        return nil, err
        --error( err )
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
        --error( strformat("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
    end

    if typ == 'OK' then
        local res = _parse_ok_packet(packet)
        if res and res.server_status&SERVER_MORE_RESULTS_EXISTS ~= 0 then
            return res, "again"
        end
        return res
    end

    if typ ~= 'DATA' then
        return nil, "packet type " .. typ .. " not supported"
        --error( "packet type " .. typ .. " not supported" )
    end

    -- typ == 'DATA'

    local field_count, extra = _parse_result_set_header_packet(packet)

    local cols = {}
    for i = 1, field_count do
        local col, err, errno, sqlstate = _recv_field_packet(self, sock)
        if not col then
            return nil, err, errno, sqlstate
            --error( strformat("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
        end

        cols[i] = col
    end

    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        --error( err)
        return nil, err
    end

    if typ ~= 'EOF' then
        --error ( "unexpected packet type " .. typ .. " while eof packet is ".. "expected" )
        return nil, "unexpected packet type " .. typ .. " while eof packet is ".. "expected"
    end

    -- typ == 'EOF'

    local compact = self.compact

    local rows = {}
    local i = 0
    while true do
        packet, typ, err = _recv_packet(self, sock)
        if not packet then
            --error (err)
            return nil, err
        end

        if typ == 'EOF' then
            local warning_count, status_flags = _parse_eof_packet(packet)

            if status_flags&SERVER_MORE_RESULTS_EXISTS ~= 0 then
                return rows, "again"
            end

            break
        end

        -- if typ ~= 'DATA' then
            -- return nil, 'bad row packet type: ' .. typ
        -- end

        -- typ == 'DATA'

        local row = _parse_row_data_packet(packet, cols, compact)
        i = i + 1
        rows[i] = row
    end

    return rows
end

local function _query_resp(self)
     return function(sock)
        local res, err, errno, sqlstate = read_result(self,sock)
        if not res then
            local badresult ={}
            badresult.badresult = true
            badresult.err = err
            badresult.errno = errno
            badresult.sqlstate = sqlstate
            return true , badresult
        end
        if err ~= "again" then
            return true, res
        end
        local multiresultset = {res}
        multiresultset.multiresultset = true
        local i =2
        while err =="again" do
            res, err, errno, sqlstate = read_result(self,sock)
            if not res then
                multiresultset.badresult = true
                multiresultset.err = err
                multiresultset.errno = errno
                multiresultset.sqlstate = sqlstate
                return true, multiresultset
            end
            multiresultset[i]=res
            i=i+1
        end
        return true, multiresultset
    end
end

function _M.connect(opts)
    local self = setmetatable( {stmts = {}}, mt)

    local max_packet_size = opts.max_packet_size
    if not max_packet_size then
        max_packet_size = 1024 * 1024 -- default 1 MB
    end
    self._max_packet_size = max_packet_size
    self.compact = opts.compact_arrays


    local database = opts.database or ""
    local user = opts.user or ""
    local password = opts.password or ""

    local channel = socketchannel.channel {
        host = opts.host,
        port = opts.port or 3306,
        auth = _mysql_login(self,user,password,database,opts.on_connect),
		overload = opts.overload,
    }
    self.sockchannel = channel
    -- try connect first only once
    channel:connect(true)


    return self
end



function _M.disconnect(self)
    self.sockchannel:close()
    setmetatable(self, nil)
end


function _M.query(self, query)
    local querypacket = _compose_query(self, query)
    local sockchannel = self.sockchannel
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return  sockchannel:request( querypacket, self.query_resp )
end

local function read_prepare_result(self, sock)
    local resp = {}
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        resp.badresult = true
        resp.errno = 300101
        resp.err = err
        return false, resp
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        resp.badresult = true
        resp.errno = errno
        resp.err = msg
        resp.sqlstate = sqlstate
        return true, resp
    end

    --第一节只能是OK
    if typ ~= "OK" then
        resp.badresult = true
        resp.errno = 300201
        resp.err = "first typ must be OK,now"..typ
        return false,resp
    end
    local pos
    resp.prepare_id,pos = _get_byte4(packet,2)
    resp.field_count,pos = _get_byte2(packet,pos)
    resp.param_count,pos = _get_byte2(packet,pos)
    resp.warning_count = _get_byte2(packet,pos+1)

    resp.params = {}
    resp.fields = {}

    if resp.param_count >0 then
        local param = _recv_field_packet(self,sock)
        while param do
            table.insert(resp.params,param)
            param = _recv_field_packet(self,sock)
        end
    end
    if resp.field_count>0 then
        local field = _recv_field_packet(self,sock)
        while field do
            table.insert(resp.fields,field)
            field = _recv_field_packet(self,sock)
        end
    end

    return true,resp
end

local function _prepare_resp(self,sql)
     return function(sock)
        return read_prepare_result(self,sock,sql)
    end
end

-- 注册预处理语句
function _prepare(self,query)
    local stmt = self.stmts[query]
    if stmt then
        return stmt
    end

    local querypacket = _compose_stmt_prepare(self, query)
    local sockchannel = self.sockchannel
    if not self.prepare_resp then
        self.prepare_resp = _prepare_resp(self)
    end
    stmt = sockchannel:request( querypacket, self.prepare_resp )
    if stmt then
        self.stmts[query] = stmt
    end

    return stmt
end

local function _get_datetime(data,pos)
    local len,year,month,day,hour,minute,second
    local value
    len,pos = _from_length_coded_bin(data,pos)
    if len==7 then
        year,pos=_get_byte2(data,pos)
        month,pos=_get_byte1(data,pos)
        day,pos=_get_byte1(data,pos)
        hour,pos=_get_byte1(data,pos)
        minute,pos=_get_byte1(data,pos)
        second,pos=_get_byte1(data,pos)
        value = strformat("%04d-%02d-%02d %02d:%02d:%02d",year,month,day,hour,minute,second)
    else
        value = "2017-09-09 20:08:09"
        --unsupported format
        pos=pos+len
    end
    return value,pos
end

local _binary_parser = {
    [0x01] = _get_byte1,
    [0x02] = _get_byte2,
    [0x03] = _get_byte4,
    [0x04] = _get_float,
    [0x05] = _get_double,
    [0x07] = _get_datetime,
    [0x08] = _get_byte8,
    [0x0c] = _get_datetime,
    [0x0f] = _from_length_coded_str,
    [0x10] = _from_length_coded_str,
    [0xf9] = _from_length_coded_str,
    [0xfa] = _from_length_coded_str,
    [0xfb] = _from_length_coded_str,
    [0xfc] = _from_length_coded_str,
    [0xfd] = _from_length_coded_str,
    [0xfe] = _from_length_coded_str,
}

local function _parse_row_data_binary(data, cols, compact)
    local ncols = #cols
    local null_count=mathfloor((ncols+7+2)/8)
    local pos = 2+null_count
    local value

    --空字段表
    local null_fields= {}
    local field_index=1
    local byte
    for i=2,pos-1 do
        byte = strbyte(data,i)
        for j=0,7 do
            if field_index>2 then
                if byte&(1<<j)==0 then
                    null_fields[field_index-2]=false
                else
                    null_fields[field_index-2]=true
                end
            end
            field_index=field_index+1
        end
    end

    local row = {}
    local parser
    for i = 1, ncols do
        local col = cols[i]
        local typ = col.type
        local name = col.name

        if not null_fields[i] then
            parser = _binary_parser[typ]
            if not parser then
                error("_parse_row_data_binary()error,unsupported field type "..typ)
            end
            value,pos = parser(data,pos)

            if compact then
                row[i] = value
            else
                row[name] = value
            end
        end
    end

    return row
end

local function read_execute_result(self,sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        return nil, err
        --error( err )
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
        --error( strformat("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
    end

    if typ == 'OK' then
        local res = _parse_ok_packet(packet)
        if res and res.server_status&SERVER_MORE_RESULTS_EXISTS ~= 0 then
            return res, "again"
        end
        return res
    end

    if typ ~= 'DATA' then
        return nil, "packet type " .. typ .. " not supported"
        --error( "packet type " .. typ .. " not supported" )
    end

    -- typ == 'DATA'

    local field_count, extra = _parse_result_set_header_packet(packet)

    local cols = {}
    local col
    while true do
        packet, typ, err = _recv_packet(self, sock)
        if typ=="EOF" then
            local warning_count, status_flags = _parse_eof_packet(packet)
            break
        end

        col = _parse_field_packet(packet)
        if not col then
            break
            --error( strformat("errno:%d, msg:%s,sqlstate:%s",errno,msg,sqlstate))
        end

        table.insert(cols,col)
    end

    --没有记录集返回
    if #cols<1 then
        return {}
    end

    local compact = self.compact
    local rows = {}
    local row
    while true do
        packet, typ, err = _recv_packet(self, sock)

        if typ=="EOF" then
            local warning_count, status_flags = _parse_eof_packet(packet)
            if status_flags&SERVER_MORE_RESULTS_EXISTS ~= 0 then
                return rows, "again"
            end
            break
        end

        row = _parse_row_data_binary(packet,cols,compact)
        if not col then
            break
        end

        table.insert(rows,row)
    end

    return rows
end

local function _execute_resp(self)
     return function(sock)
        local res, err, errno, sqlstate = read_execute_result(self,sock)
        if not res then
            local badresult ={}
            badresult.badresult = true
            badresult.err = err
            badresult.errno = errno
            badresult.sqlstate = sqlstate
            return true , badresult
        end
        if err ~= "again" then
            return true, res
        end
        local mulitresultset = {res}
        mulitresultset.mulitresultset = true
        local i =2
        while err =="again" do
            res, err, errno, sqlstate = read_execute_result(self,sock)
            if not res then
                mulitresultset.badresult = true
                mulitresultset.err = err
                mulitresultset.errno = errno
                mulitresultset.sqlstate = sqlstate
                return true, mulitresultset
            end
            mulitresultset[i]=res
            i=i+1
        end
        return true, mulitresultset
     end
end

--[[
    执行sql语句
    失败返回字段
        errno
        badresult
        sqlstate
        err
]]
function _M.execute(self, sql,...)
    local p_n = select('#',...)
    local p_v
    for i=1,p_n do
        p_v = select(i,...)
        if p_v==nil then
            return {
                badresult=true,
                errno=30902,
                err="prepare sql fail : "..sql,
            }
        end
    end

    local args = {...}

    local stmt=_prepare(self,sql)
    if not stmt then
        return {
            badresult=true,
            errno=30901,
            err="prepare sql fail : "..sql,
            }
    end
    if stmt.badresult then
        return stmt
    end

    local querypacket,er = _compose_stmt_execute(self,stmt,CURSOR_TYPE_NO_CURSOR,args)
    if not querypacket then
        return {
            badresult=true,
            errno=30902,
            err=er,
        }
    end
    local sockchannel = self.sockchannel
    if not self.execute_resp then
        self.execute_resp = _execute_resp(self)
    end
    return sockchannel:request( querypacket, self.execute_resp )
end

function _M.ping(self)
    local querypacket,er = _compose_ping(self)
    if not querypacket then
        return {
            badresult=true,
            errno=30902,
            err=er,
        }
    end
    local sockchannel = self.sockchannel
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return sockchannel:request( querypacket, self.query_resp )
end

function _M.server_ver(self)
    return self._server_ver
end

local escape_map = {
	['\0'] = "\\0",
	['\b'] = "\\b",
	['\n'] = "\\n",
	['\r'] = "\\r",
	['\t'] = "\\t",
	['\26'] = "\\Z",
	['\\'] = "\\\\",
	["'"] = "\\'",
	['"'] = '\\"',
}

function _M.quote_sql_str( str)
	return strformat("'%s'", strgsub(str, "[\0\b\n\r\t\26\\\'\"]", escape_map))
end

function _M.set_compact_arrays(self, value)
    self.compact = value
end


return _M
