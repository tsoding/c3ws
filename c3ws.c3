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
module c3ws(<Socket, CHUNK_SIZE>);

// TODO: run on https://github.com/crossbario/autobahn-testsuite

import libc;
import std::io;
import std::hash::sha1;
import std::encoding::base64;
import std::net::os;

fn void! Socket.read_entire_buffer(&self, char[] buffer) {
    while (buffer.len > 0) {
        usz n = self.read(buffer)!;
        buffer = buffer[n..];
    }
}

// TODO: move Socket.peek into the std and make a PR to c3 maybe?
fn usz! Socket.peek(&self, char[] bytes) @dynamic
{
$if env::WIN32:
    $error("Win32 is not support yet");
    isz n = libc::recv(self.sock, bytes.ptr, (int)bytes.len, MSG_PEEK);
$else
    const int MSG_PEEK = 2;
    isz n = libc::recv(self.sock, bytes.ptr, bytes.len, MSG_PEEK);
$endif
    if (n < 0) return os::socket_error()?;
    return (usz)n;
}

distinct Ws_Opcode = char;
const Ws_Opcode OPCODE_CONT  = 0x0;
const Ws_Opcode OPCODE_TEXT  = 0x1;
const Ws_Opcode OPCODE_BIN   = 0x2;
const Ws_Opcode OPCODE_CLOSE = 0x8;
const Ws_Opcode OPCODE_PING  = 0x9;
const Ws_Opcode OPCODE_PONG  = 0xA;

fn String opcode_name(Ws_Opcode opcode)
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

fn bool opcode_is_control(Ws_Opcode opcode)
{
    return 0x8 <= opcode && opcode <= 0xF;
}

struct Ws_Frame {
    bool fin;
    Ws_Opcode opcode;
    char[] payload;
}

distinct Ws_Message_Kind = char;
const Ws_Message_Kind MESSAGE_TEXT = (Ws_Message_Kind) OPCODE_TEXT;
const Ws_Message_Kind MESSAGE_BIN  = (Ws_Message_Kind) OPCODE_BIN;

struct Ws_Message_Chunk {
    Ws_Message_Chunk *next;
    char[] payload;
}

struct Ws_Message {
    Ws_Message_Kind kind;
    Ws_Message_Chunk *chunks;
}

fault Ws_Error {
    // Ws.client_handshake() has failed
    CLIENT_HANDSHAKE_BAD_RESPONSE,
    CLIENT_HANDSHAKE_NO_ACCEPT,
    CLIENT_HANDSHAKE_DUPLICATE_ACCEPT,
    CLIENT_HANDSHAKE_BAD_ACCEPT,
    // Ws.server_handshake() has failed
    SERVER_HANDSHAKE_BAD_REQUEST,
    SERVER_HANDSHAKE_NO_KEY,
    SERVER_HANDSHAKE_DUPLICATE_KEY,
    // Socket.read or Socket.write have failed
    SOCKET_ERROR,
    // Server sent CLOSE frame during Ws.read_message()
    SERVER_CLOSE_ERROR,
}

struct Ws {
    Socket socket;
}

fn String! parse_sec_websocket_accept_from_response(String *response) {
    bool found_sec_websocket_accept = false;
    String sec_websocket_accept;
    const String LINE_SEP = "\r\n";
    const String HEADER_SEP = ":";

    // TODO: verify the response status line
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

fn void! Ws.server_handshake(ws)
{
    // TODO: Ws.server_handshake assumes that request fits into 1024 bytes
    char[1024] buffer;
    usz buffer_size = ws.socket.peek(&buffer)!;
    String request = (String)buffer[0:buffer_size];
    String sec_websocket_key = parse_sec_websocket_key_from_request(&request)!;
    ws.socket.read(buffer[0:buffer_size - request.len])!;

    DString handshake;
    handshake.new_init(1024, allocator::temp());
    handshake.append("HTTP/1.1 101 Switching Protocols\r\n");
    handshake.append("Upgrade: websocket\r\n");
    handshake.append("Connection: Upgrade\r\n");
    handshake.appendf("Sec-WebSocket-Accept: %s\r\n", compute_sec_websocket_accept(sec_websocket_key));
    handshake.append("\r\n");
    ws.socket.write(handshake.str_view())!;
}

// https://datatracker.ietf.org/doc/html/rfc6455#section-1.3
// TODO: Ws.client_handshake should accept a URL
fn void! Ws.client_handshake(ws, String host)
{
    DString handshake;
    handshake.new_init(1024, allocator::temp());
    // TODO: customizable resource path
    handshake.append("GET / HTTP/1.1\r\n");
    handshake.appendf("Host: %s\r\n", host);
    handshake.append("Upgrade: websocket\r\n");
    handshake.append("Connection: Upgrade\r\n");
    // TODO: custom WebSocket key
    handshake.append("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
    handshake.append("Sec-WebSocket-Version: 13\r\n");
    handshake.append("\r\n");

    ws.socket.write(handshake.str_view())!;

    // TODO: Ws.client_handshake assumes that response fits into 1024 bytes
    char[1024] buffer;
    usz buffer_size = ws.socket.peek(&buffer)!;
    String response = (String)buffer[0:buffer_size];
    String sec_websocket_accept = parse_sec_websocket_accept_from_response(&response)!;
    ws.socket.read(buffer[0:buffer_size - response.len])!;
    if (sec_websocket_accept != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") return Ws_Error.CLIENT_HANDSHAKE_BAD_ACCEPT?;
}

fn void! Ws.send_frame(ws, bool fin, Ws_Opcode opcode, char[] payload)
{
    // Send FIN and OPCODE
    {
        // NOTE: FIN is always set
        char data = (char) opcode;
        if (fin) data |= (1 << 7);
        ws.socket.write((&data)[0:1])!;
    }

    // Send masked and payload length
    {
        // TODO: do we need to reverse the bytes on a machine with a different endianess than x86?
        // NOTE: client frames are always masked
        if (payload.len < 126) {
            char data = (1 << 7) | (char) payload.len;
            ws.socket.write((&data)[0:1])!;
        } else if (payload.len <= ushort.max) {
            char data = (1 << 7) | 126;
            ws.socket.write((&data)[0:1])!;

            char[2] len = {
                (char)(payload.len >> (8 * 1)) & 0xFF,
                (char)(payload.len >> (8 * 0)) & 0xFF
            };

            ws.socket.write(&len)!;
        } else if (payload.len > ushort.max) {
            char data = (1 << 7) | 127;
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

            ws.socket.write((&data)[0:1])!;
            ws.socket.write(&len)!;
        }
    }

    char[4] mask = {};

    // Generate and send mask
    {
        // TODO: use the rand from the standard library
        foreach (&byte: mask) *byte = (char)(libc::rand() % 0x100);
        ws.socket.write(&mask)!;
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
        ws.socket.write(chunk[0:chunk_size])!;
    }
}

fn void! Ws.send_message(ws, Ws_Message_Kind kind, char[] payload, uint chunk_len)
{
    bool first = true;
    while (payload.len > 0) {
        uint len = payload.len;
        if (len > chunk_len) len = chunk_len;
        ws.send_frame(payload.len - len == 0, first ? (Ws_Opcode) kind : OPCODE_CONT, payload[0:len])!;
        payload = payload[len..];
        first = false;
    }
}

fn void! Ws.send_text(ws, String text)
{
    return ws.send_message(MESSAGE_TEXT, text, CHUNK_SIZE);
}

fn void! Ws.send_binary(ws, char[] binary)
{
    return ws.send_message(MESSAGE_BIN, binary, CHUNK_SIZE);
}

macro char fIN(char[2] header)         => ((header)[0] >> 7);
macro char oPCODE(char[2] header)      => ((header)[0] & 0xF);
macro char mASK(char[2] header)        => ((header)[1] >> 7);
macro char pAYLOAD_LEN(char[2] header) => ((header)[1] & 0x7F);

fn Ws_Frame*! Ws.read_frame(ws)
{
    char[2] header;

    // Read the header
    ws.socket.read_entire_buffer(&header)!;

    uint payload_len = 0;

    // Parse the payload length
    {
        // TODO: do we need to reverse the bytes on a machine with a different endianess than x86?
        char len = pAYLOAD_LEN(header);
        switch (len) {
        case 126: {
            char[2] ext_len = {};
            ws.socket.read_entire_buffer(&ext_len)!;

            for (usz i = 0; i < ext_len.len; ++i) {
                payload_len = (payload_len << 8) | ext_len[i];
            }
        }
        break;
        case 127: {
            char[8] ext_len = {};
            ws.socket.read_entire_buffer(&ext_len)!;

            for (usz i = 0; i < ext_len.len; ++i) {
                payload_len = (payload_len << 8) | ext_len[i];
            }
        }
        break;
        default:
            payload_len = len;
        }
    }

    // Read the mask
    // TODO: the server may not send masked frames
    char[4] mask;
    bool masked = (bool) mASK(header);
    if (masked) {
        ws.socket.read_entire_buffer(&mask)!;
    }

    // Read the payload
    {
        Ws_Frame *frame = mem::temp_new(Ws_Frame);
        frame.fin = (bool) fIN(header);
        frame.opcode = (Ws_Opcode) oPCODE(header);
        frame.payload = mem::temp_new_array(char, payload_len);

        if (frame.payload.len > 0) {
            ws.socket.read_entire_buffer(frame.payload)!;
            if (masked) {
                foreach (i, &x: frame.payload) {
                    *x ^= mask[i % 4];
                }
            }
        }

        return frame;
    }
}

fn Ws_Message*! Ws.read_message(ws)
{
    Ws_Message_Chunk *end = null;
    Ws_Message *message = mem::temp_alloc(Ws_Message);
    message.chunks = null;

    while (try frame = ws.read_frame()) {
        if (opcode_is_control(frame.opcode)) {
            switch (frame.opcode) {
            case OPCODE_CLOSE:
                return Ws_Error.SERVER_CLOSE_ERROR?;
            case OPCODE_PING:
                ws.send_frame(true, OPCODE_PONG, frame.payload)!;
                break;
            default: {
                // Ignore any other control frames for now
            }
            }
        } else {
            // TODO: ws.read_message does not verify that the message starts with non CONT frame (does it have to start with non-CONT frame)?
            // TODO: ws.read_message does not verify that any non-fin "continuation" frames have the CONT opcode
            if (end == null) {
                end = mem::temp_alloc(Ws_Message_Chunk);
                end.next = null;
                end.payload = frame.payload;
                message.chunks = end;
                message.kind = (Ws_Message_Kind) frame.opcode;
            } else {
                end.next = mem::temp_alloc(Ws_Message_Chunk);
                end.next.next = null;
                end.next.payload = frame.payload;
                end = end.next;
            }

            if (frame.fin) break;
        }
    }

    return message;
}

// TODO: Ws.read() does not report what kind of message we received: TEXT or BIN
fn char[]! Ws.read(ws)
{
    Ws_Message* message = ws.read_message()!;
    DString payload;
    payload.new_init(1024, allocator::temp());
    for (Ws_Message_Chunk *iter = message.chunks; iter != null; iter = iter.next) {
        payload.append(iter.payload);
    }
    return payload.tcopy_str();
}


fn String compute_sec_websocket_accept(String sec_websocket_key)
{
    char[sha1::HASH_BYTES] src = sha1::hash(string::tformat("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", sec_websocket_key));
    Base64Encoder encoder;
    encoder.init(base64::STD_ALPHABET)!!;
    char[] dst = mem::temp_new_array(char, encoder.encode_len(src.len));
    encoder.encode(&src, dst)!!;
    return (String)dst;
}
