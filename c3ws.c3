// Copyright 2024 Alexey Kutepov <reximkut@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
module c3ws(<Socket, CLIENT>);

// TODO: run autobahn testsuit on CI and deploy reports to github pages

import libc;
import std::io;
import std::net::os;
import std::core::string;

// TODO: Make the CHUNK_SIZE customizable somehow, but not via generics (they are too noisy)
const int CHUNK_SIZE = 1024;

fn void! Ws.read_entire_buffer_raw(&self, char[] buffer) {
    while (buffer.len > 0) {
        usz n = self.socket.read(buffer)!;
        buffer = buffer[n..];
    }
}

fn void! Ws.write_entire_buffer_raw(&self, char[] buffer) {
    while (buffer.len > 0) {
        usz n = self.socket.write(buffer)!;
        buffer = buffer[n..];
    }
}

// TODO: Add something like Socket.peek to the std and make a PR to c3 maybe?
fn usz! Ws.peek_raw(&self, char[] bytes) @dynamic
{
$if env::WIN32:
    $error("Win32 is not support yet");
    isz n = libc::recv(self.socket.sock, bytes.ptr, (int)bytes.len, MSG_PEEK);
$else
    const int MSG_PEEK = 2;
    isz n = libc::recv(self.socket.sock, bytes.ptr, bytes.len, MSG_PEEK);
$endif
    if (n < 0) return os::socket_error()?;
    return (usz)n;
}

struct Ws {
    Socket socket;
    bool debug; // Enable debug logging
}

fn void! Ws.server_handshake(ws)
{
    // TODO: Ws.server_handshake assumes that request fits into 1024 bytes
    char[1024] buffer;
    usz buffer_size = ws.peek_raw(&buffer)!;
    String request = (String)buffer[0:buffer_size];
    String sec_websocket_key = ws::parse_sec_websocket_key_from_request(&request)!;
    ws.socket.read(buffer[0:buffer_size - request.len])!;

    DString handshake;
    handshake.new_init(1024, allocator::temp());
    handshake.append("HTTP/1.1 101 Switching Protocols\r\n");
    handshake.append("Upgrade: websocket\r\n");
    handshake.append("Connection: Upgrade\r\n");
    handshake.appendf("Sec-WebSocket-Accept: %s\r\n", ws::compute_sec_websocket_accept(sec_websocket_key));
    handshake.append("\r\n");
    ws.socket.write(handshake.str_view())!;
}

// https://datatracker.ietf.org/doc/html/rfc6455#section-1.3
// TODO: Ws.client_handshake should just accept a ws/wss URL
fn void! Ws.client_handshake(ws, String host, String endpoint = "/")
{
    DString handshake;
    handshake.new_init(1024, allocator::temp());
    // TODO: customizable resource path
    handshake.appendf("GET %s HTTP/1.1\r\n", endpoint);
    handshake.appendf("Host: %s\r\n", host);
    handshake.append("Upgrade: websocket\r\n");
    handshake.append("Connection: Upgrade\r\n");
    // TODO: Custom WebSocket key
    // Maybe even hardcode something that identifies c3ws?
    handshake.append("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
    handshake.append("Sec-WebSocket-Version: 13\r\n");
    handshake.append("\r\n");

    ws.socket.write(handshake.str_view())!;

    // TODO: Ws.client_handshake assumes that response fits into 1024 bytes
    char[1024] buffer;
    usz buffer_size = ws.peek_raw(&buffer)!;
    String response = (String)buffer[0:buffer_size];
    String sec_websocket_accept = ws::parse_sec_websocket_accept_from_response(&response)!;
    ws.socket.read(buffer[0:buffer_size - response.len])!;
    if (sec_websocket_accept != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") return Ws_Error.CLIENT_HANDSHAKE_BAD_ACCEPT?;
}

fn void! Ws.send_frame(ws, bool fin, Ws_Opcode opcode, char[] payload)
{
    if (ws.debug) {
        io::printfn("C3WS DEBUG: TX FRAME: FIN(%d), OPCODE(%s), RSV(000), PAYLOAD_LEN: %d",
                    fin,
                    opcode.name(),
                    payload.len);
    }

    // Send FIN and OPCODE
    {
        // NOTE: FIN is always set
        char data = (char) opcode;
        if (fin) data |= (1 << 7);
        ws.write_entire_buffer_raw((&data)[0:1])!;
    }

    // Send masked and payload length
    {
        // TODO: do we need to reverse the bytes on a machine with a different endianess than x86?
        // NOTE: client frames are always masked
        if (payload.len < 126) {
            char data = CLIENT ? (1 << 7) : 0;
            data |= (char) payload.len;
            ws.write_entire_buffer_raw((&data)[0:1])!;
        } else if (payload.len <= ushort.max) {
            char data = CLIENT ? (1 << 7) : 0;
            data |= 126;
            ws.write_entire_buffer_raw((&data)[0:1])!;

            char[2] len = {
                (char)(payload.len >> (8 * 1)) & 0xFF,
                (char)(payload.len >> (8 * 0)) & 0xFF
            };

            ws.write_entire_buffer_raw(&len)!;
        } else if (payload.len > ushort.max) {
            char data = CLIENT ? (1 << 7) : 0;
            data |= 127;
            char[8] len = {
                (char) (payload.len >> (8 * 7)) & 0xFF,
                (char) (payload.len >> (8 * 6)) & 0xFF,
                (char) (payload.len >> (8 * 5)) & 0xFF,
                (char) (payload.len >> (8 * 4)) & 0xFF,
                (char) (payload.len >> (8 * 3)) & 0xFF,
                (char) (payload.len >> (8 * 2)) & 0xFF,
                (char) (payload.len >> (8 * 1)) & 0xFF,
                (char) (payload.len >> (8 * 0)) & 0xFF
            };

            ws.write_entire_buffer_raw((&data)[0:1])!;
            ws.write_entire_buffer_raw(&len)!;
        }
    }

    if (CLIENT) {
        char[4] mask = {};

        // Generate and send mask
        {
            // TODO: use the rand from the standard library
            foreach (&byte: mask) *byte = (char)(libc::rand() % 0x100);
            ws.write_entire_buffer_raw(&mask)!;
        }

        // Mask the payload and send it
        for (uint i = 0; i < payload.len; ) {
            char[1024] chunk;
            uint chunk_size = 0;
            while (i < payload.len && chunk_size < chunk.len) {
                chunk[chunk_size] = payload[i] ^ mask[i % 4];
                chunk_size += 1;
                i += 1;
            }
            ws.write_entire_buffer_raw(chunk[0:chunk_size])!;
        }
    } else {
        ws.write_entire_buffer_raw(payload)!;
    }
}

fn void! Ws.send_message(ws, Ws_Message_Kind kind, char[] payload)
{
    bool first = true;
    do {
        uint len = payload.len;
        if (len > CHUNK_SIZE) len = CHUNK_SIZE;
        bool fin = payload.len - len == 0;
        Ws_Opcode opcode = first ? (Ws_Opcode) kind : ws::OPCODE_CONT;

        ws.send_frame(fin, opcode, payload[0:len])!;
        payload = payload[len..];
        first = false;
    } while(payload.len > 0);
}

fn void! Ws.send_text(ws, String text)
{
    return ws.send_message(ws::MESSAGE_TEXT, text);
}

fn void! Ws.send_binary(ws, char[] binary)
{
    return ws.send_message(ws::MESSAGE_BIN, binary);
}

fn Ws_Frame_Header! Ws.read_frame_header(ws)
{
    char[2] header;

    // Read the header
    ws.read_entire_buffer_raw(&header)!;
    Ws_Frame_Header frame_header = {
        .fin = (bool) ws::fIN(header),
        .rsv1 = (bool) ws::rSV1(header),
        .rsv2 = (bool) ws::rSV2(header),
        .rsv3 = (bool) ws::rSV3(header),
        .opcode = (Ws_Opcode) ws::oPCODE(header),
        .masked = (bool) ws::mASK(header),
    };

    // Parse the payload length
    {
        // TODO: do we need to reverse the bytes on a machine with a different endianess than x86?
        char len = ws::pAYLOAD_LEN(header);
        switch (len) {
        case 126:
            char[2] ext_len = {};
            ws.read_entire_buffer_raw(&ext_len)!;

            for (usz i = 0; i < ext_len.len; ++i) {
                frame_header.payload_len = (frame_header.payload_len << 8) | ext_len[i];
            }
        case 127:
            char[8] ext_len = {};
            ws.read_entire_buffer_raw(&ext_len)!;

            for (usz i = 0; i < ext_len.len; ++i) {
                frame_header.payload_len = (frame_header.payload_len << 8) | ext_len[i];
            }
        default:
            frame_header.payload_len = len;
        }
    }

    if (ws.debug) {
        io::printfn("C3WS DEBUG: RX FRAME: FIN(%d), OPCODE(%s), RSV(%d%d%d), PAYLOAD_LEN: %d",
                    frame_header.fin,
                    frame_header.opcode.name(),
                    frame_header.rsv1, frame_header.rsv2, frame_header.rsv3,
                    frame_header.payload_len);
    }

    // RFC 6455 - Section 5.5:
    // > All control frames MUST have a payload length of 125 bytes or less
    // > and MUST NOT be fragmented.
    if (frame_header.opcode.is_control() && (frame_header.payload_len > 125 || !frame_header.fin)) {
        return Ws_Error.CONTROL_FRAME_TOO_BIG?;
    }

    // RFC 6455 - Section 5.2:
    // >  RSV1, RSV2, RSV3:  1 bit each
    // >
    // >     MUST be 0 unless an extension is negotiated that defines meanings
    // >     for non-zero values.  If a nonzero value is received and none of
    // >     the negotiated extensions defines the meaning of such a nonzero
    // >     value, the receiving endpoint MUST _Fail the WebSocket
    // >     Connection_.
    if (frame_header.rsv1 || frame_header.rsv2 || frame_header.rsv3) {
        return Ws_Error.RESERVED_BITS_NOT_NEGOTIATED?;
    }

    // Read the mask if masked
    if (frame_header.masked) ws.read_entire_buffer_raw(&frame_header.mask)!;

    return frame_header;
}

fn usz! Ws.read_frame_payload_chunk(ws, Ws_Frame_Header frame_header, char[] payload, usz payload_size)
{
    assert(frame_header.payload_len == payload.len);
    if (payload_size >= payload.len) return 0;
    char[] unfinished_payload = payload[payload_size..];
    usz n = ws.socket.read(unfinished_payload)!;
    if (frame_header.masked) {
        foreach (i, &x: unfinished_payload) {
            *x ^= frame_header.mask[(payload_size + i) % 4];
        }
    }
    return n;
}

fn char[]! Ws.read_frame_entire_payload(ws, Ws_Frame_Header frame_header) {
    char[] payload = mem::temp_new_array(char, frame_header.payload_len);
    usz payload_size = 0;
    while (payload_size < payload.len) {
        payload_size += ws.read_frame_payload_chunk(frame_header, payload, payload_size)!;
    }
    return payload;
}

fn Ws_Message! Ws.read_message(ws)
{
    Ws_Message message;
    DString payload;
    payload.new_init(1024, allocator::temp());
    bool cont = false;
    usz verify_pos = 0;

    for (;;) {
        Ws_Frame_Header frame = ws.read_frame_header()!;
        if (frame.opcode.is_control()) {
            switch (frame.opcode) {
            case ws::OPCODE_CLOSE:
                return Ws_Error.CLOSE_FRAME_SENT?;
            case ws::OPCODE_PING:
                ws.send_frame(true, ws::OPCODE_PONG, ws.read_frame_entire_payload(frame)!)!;
            case ws::OPCODE_PONG:
                ws.read_frame_entire_payload(frame)!;
                // Unsolicited PONGs are just ignored
                break;
            default:
                return Ws_Error.UNEXPECTED_OPCODE?;
            }
        } else {
            if (!cont) {
                switch (frame.opcode) {
                case ws::OPCODE_TEXT:
                case ws::OPCODE_BIN:
                    message.kind = (Ws_Message_Kind) frame.opcode;
                default:
                    return Ws_Error.UNEXPECTED_OPCODE?;
                }
                cont = true;
            } else {
                if (frame.opcode != ws::OPCODE_CONT) {
                    return Ws_Error.UNEXPECTED_OPCODE?;
                }
            }
            char[] frame_payload = mem::temp_new_array(char, frame.payload_len);
            usz frame_payload_size = 0;
            while (frame_payload_size < frame_payload.len) {
                usz n = ws.read_frame_payload_chunk(frame, frame_payload, frame_payload_size)!;
                payload.append(frame_payload[frame_payload_size:n]);
                frame_payload_size += n;
                if (message.kind == ws::MESSAGE_TEXT) {
                    // Verifying UTF-8
                    while VERIFY: (verify_pos < payload.len()) {
                        usz size = payload.len() - verify_pos;
                        if (catch excuse = ws::utf8_to_char32_fixed(&payload.str_view()[verify_pos], &size)) {
                            case ExtraUnicodeResult.SHORT_UTF8:
                                if (!frame.fin) {
                                    usz saved_len = payload.len();
                                    payload.extend_unfinished_utf8(verify_pos);
                                    size = payload.len() - verify_pos;
                                    ws::utf8_to_char32_fixed(&payload.str_view()[verify_pos], &size)!;
                                    payload.chop(saved_len);
                                    break VERIFY; // Tolerating the unfinished UTF-8 sequences if the message is unfinished
                                }
                                nextcase;
                            default:
                                return excuse?; // Fail-fast on invalid UTF-8
                        }
                        verify_pos += size;
                    }
                }
            }
            if (frame.fin) break;
        }
    }

    message.payload = payload.str_view();

    return message;
}

module c3ws::ws;

import std::hash::sha1;
import std::encoding::base64;

fault Ws_Error {
    // Client Handshake Errors
    CLIENT_HANDSHAKE_BAD_RESPONSE,
    CLIENT_HANDSHAKE_NO_ACCEPT,
    CLIENT_HANDSHAKE_DUPLICATE_ACCEPT,
    CLIENT_HANDSHAKE_BAD_ACCEPT,
    // Server Handshake Errors
    SERVER_HANDSHAKE_BAD_REQUEST,
    SERVER_HANDSHAKE_NO_KEY,
    SERVER_HANDSHAKE_DUPLICATE_KEY,
    // Connection Errors
    CLOSE_FRAME_SENT,
    CONTROL_FRAME_TOO_BIG,
    RESERVED_BITS_NOT_NEGOTIATED,
    UNEXPECTED_OPCODE,
}

macro char fIN(char[2] header)         => (((header)[0] >> 7)&0x1);
macro char rSV1(char[2] header)        => (((header)[0] >> 6)&0x1);
macro char rSV2(char[2] header)        => (((header)[0] >> 5)&0x1);
macro char rSV3(char[2] header)        => (((header)[0] >> 4)&0x1);
macro char oPCODE(char[2] header)      => ((header)[0] & 0xF);
macro char mASK(char[2] header)        => ((header)[1] >> 7);
macro char pAYLOAD_LEN(char[2] header) => ((header)[1] & 0x7F);

fn String compute_sec_websocket_accept(String sec_websocket_key)
{
    char[sha1::HASH_BYTES] src = sha1::hash(string::tformat("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", sec_websocket_key));
    return base64::encode(&src, allocator::temp());
}

fn String! parse_sec_websocket_key_from_request(String *request) {
    bool found_sec_websocket_key = false;
    String sec_websocket_key;
    const String LINE_SEP = "\r\n";
    const String HEADER_SEP = ":";

    // TODO: verify the request status line
    if (try index = request.index_of(LINE_SEP)) {
        (*request) = (*request)[index+LINE_SEP.len..];
    } else {
        return Ws_Error.SERVER_HANDSHAKE_BAD_REQUEST?;
    }

    // TODO: verify the rest of the headers of the request
    // Right now we are only looking for Sec-WebSocket-Key
    while(request.len > 0 && !request.starts_with(LINE_SEP)) {
        String header;
        if (try index = request.index_of(LINE_SEP)) {
            header = (*request)[0:index];
            (*request) = (*request)[index+LINE_SEP.len..];
        } else {
            return Ws_Error.SERVER_HANDSHAKE_BAD_REQUEST?;
        }

        String key, value;
        if (try index = header.index_of(HEADER_SEP)) {
            key = header[0:index].trim();
            value = header[index+HEADER_SEP.len..].trim();
        } else {
            return Ws_Error.SERVER_HANDSHAKE_BAD_REQUEST?;
        }

        if (key == "Sec-WebSocket-Key") {
            if (found_sec_websocket_key) return Ws_Error.SERVER_HANDSHAKE_DUPLICATE_KEY?;
            sec_websocket_key = value;
            found_sec_websocket_key = true;
        }
    }
    if (!request.starts_with(LINE_SEP)) return Ws_Error.SERVER_HANDSHAKE_BAD_REQUEST?;
    (*request) = (*request)[LINE_SEP.len..];
    if (!found_sec_websocket_key) return Ws_Error.SERVER_HANDSHAKE_NO_KEY?;
    return sec_websocket_key;
}

fn String! parse_sec_websocket_accept_from_response(String *response) {
    bool found_sec_websocket_accept = false;
    String sec_websocket_accept;
    const String LINE_SEP = "\r\n";
    const String HEADER_SEP = ":";

    // TODO: verify the response status line
    //   If the status code is an error one, log the message
    if (try index = response.index_of(LINE_SEP)) {
        (*response) = (*response)[index+LINE_SEP.len..];
    } else {
        return Ws_Error.CLIENT_HANDSHAKE_BAD_RESPONSE?;
    }

    // TODO: verify the rest of the headers of the response
    // Right now we are only looking for Sec-WebSocket-Accept
    while(response.len > 0 && !response.starts_with(LINE_SEP)) {
        String header;
        if (try index = response.index_of(LINE_SEP)) {
            header = (*response)[0:index];
            (*response) = (*response)[index+LINE_SEP.len..];
        } else {
            return Ws_Error.CLIENT_HANDSHAKE_BAD_RESPONSE?;
        }

        String key, value;
        if (try index = header.index_of(HEADER_SEP)) {
            key = header[0:index].trim();
            value = header[index+HEADER_SEP.len..].trim();
        } else {
            return Ws_Error.CLIENT_HANDSHAKE_BAD_RESPONSE?;
        }

        if (key == "Sec-WebSocket-Accept") {
            if (found_sec_websocket_accept) return Ws_Error.CLIENT_HANDSHAKE_DUPLICATE_ACCEPT?;
            sec_websocket_accept = value;
            found_sec_websocket_accept = true;
        }
    }
    if (!response.starts_with(LINE_SEP)) return Ws_Error.CLIENT_HANDSHAKE_BAD_RESPONSE?;
    (*response) = (*response)[LINE_SEP.len..];
    if (!found_sec_websocket_accept) return Ws_Error.CLIENT_HANDSHAKE_NO_ACCEPT?;
    return sec_websocket_accept;
}

distinct Ws_Message_Kind = char;
const Ws_Message_Kind MESSAGE_TEXT = (Ws_Message_Kind) OPCODE_TEXT;
const Ws_Message_Kind MESSAGE_BIN  = (Ws_Message_Kind) OPCODE_BIN;

struct Ws_Message {
    Ws_Message_Kind kind;
    char[] payload;
}

distinct Ws_Opcode = char;
const Ws_Opcode OPCODE_CONT  = 0x0;
const Ws_Opcode OPCODE_TEXT  = 0x1;
const Ws_Opcode OPCODE_BIN   = 0x2;
const Ws_Opcode OPCODE_CLOSE = 0x8;
const Ws_Opcode OPCODE_PING  = 0x9;
const Ws_Opcode OPCODE_PONG  = 0xA;

fn String Ws_Opcode.name(opcode)
{
    switch (opcode) {
    case OPCODE_CONT:  return "CONT";
    case OPCODE_TEXT:  return "TEXT";
    case OPCODE_BIN:   return "BIN";
    case OPCODE_CLOSE: return "CLOSE";
    case OPCODE_PING:  return "PING";
    case OPCODE_PONG:  return "PONG";
    default:
        if (0x3 <= opcode && opcode <= 0x7) {
            return string::tformat("NONCONTROL(0x%X)", opcode & 0xF);
        } else if (0xB <= opcode && opcode <= 0xF) {
            return string::tformat("CONTROL(0x%X)", opcode & 0xF);
        } else {
            return string::tformat("INVALID(0x%X)", opcode & 0xF);
        }
    }
}

fn bool Ws_Opcode.is_control(opcode)
{
    return 0x8 <= opcode && opcode <= 0xF;
}

struct Ws_Frame_Header {
    bool fin, rsv1, rsv2, rsv3;
    Ws_Opcode opcode;
    bool masked;
    usz payload_len;
    char[4] mask;
}

fault ExtraUnicodeResult {
    SHORT_UTF8
}

fn void DString.extend_unfinished_utf8(&self, usz pos)
{
    char c = self.str_view()[pos];
    usz size = 0;
    if ((c & 0x80) == 0) {
        size = 1;
    } else if ((c & 0xE0) == 0xC0) {
        size = 2;
    } else if ((c & 0xF0) == 0xE0) {
        size = 3;
    } else {
        size = 4;
    }
    while (self.len() - pos < size) self.append_char(0b1000_0000);
}

// TODO: submit utf8_to_char32_fixed to c3c
<*
 @param [in] ptr `pointer to the first character to parse`
 @param [inout] size `Set to max characters to read, set to characters read`
 @return `the parsed 32 bit codepoint`
*>
fn Char32! utf8_to_char32_fixed(char* ptr, usz* size)
{
	usz max_size = *size;
	if (max_size < 1) return ExtraUnicodeResult.SHORT_UTF8?; // NEW
	char c = (ptr++)[0];

	if ((c & 0x80) == 0)
	{
		*size = 1;
		return c;
	}
	if ((c & 0xE0) == 0xC0)
	{
		if (max_size < 2) return ExtraUnicodeResult.SHORT_UTF8?; // NEW
		*size = 2;
		Char32 uc = (c & 0x1F) << 6;
		c = *ptr;
		// Overlong sequence or invalid second.
		if (!uc || c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
		uc = uc + c & 0x3F;
        // NEW: maximum overlong sequence
        if (uc <= 0b111_1111) return UnicodeResult.INVALID_UTF8?;
		// NEW: UTF-16 surrogate pairs
		if (0xD800 <= uc && uc <= 0xDFFF) return UnicodeResult.INVALID_UTF8?;
		return uc;
	}
	if ((c & 0xF0) == 0xE0)
	{
		if (max_size < 3) return ExtraUnicodeResult.SHORT_UTF8?; // NEW
		*size = 3;
		Char32 uc = (c & 0x0F) << 12;
		c = ptr++[0];
		if (c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
		uc += (c & 0x3F) << 6;
		c = ptr++[0];
		// Overlong sequence or invalid last
		if (!uc || c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
		uc = uc + c & 0x3F;
        // NEW: maximum overlong sequence
        if (uc <= 0b11111_111111) return UnicodeResult.INVALID_UTF8?;
		// NEW: UTF-16 surrogate pairs
		if (0xD800 <= uc && uc <= 0xDFFF) return UnicodeResult.INVALID_UTF8?;
		return uc;
	}
	if (max_size < 4) return ExtraUnicodeResult.SHORT_UTF8?; // NEW
	if ((c & 0xF8) != 0xF0) return UnicodeResult.INVALID_UTF8?;
	*size = 4;
	Char32 uc = (c & 0x07) << 18;
	c = ptr++[0];
	if (c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
	uc += (c & 0x3F) << 12;
	c = ptr++[0];
	if (c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
	uc += (c & 0x3F) << 6;
	c = ptr++[0];
	// Overlong sequence or invalid last
	if (!uc || c & 0xC0 != 0x80) return UnicodeResult.INVALID_UTF8?;
	uc = uc + c & 0x3F;
	// NEW: UTF-16 surrogate pairs
	if (0xD800 <= uc && uc <= 0xDFFF) return UnicodeResult.INVALID_UTF8?;
    // NEW: maximum overlong sequence
    if (uc <= 0b1111_111111_111111) return UnicodeResult.INVALID_UTF8?;
	// NEW: Maximum valid Unicode number
	if (uc > 0x10FFFF) return UnicodeResult.INVALID_UTF8?;
	return uc;
}
