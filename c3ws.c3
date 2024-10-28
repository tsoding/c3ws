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

import libc;
import std::io;
import std::hash::sha1;
import std::encoding::base64;

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
    CLIENT_HANDSHAKE_ERROR,
    // Ws.server_handshake() has failed
    SERVER_HANDSHAKE_BAD_REQUEST,
    SERVER_HANDSHAKE_NO_KEY,
    // Socket.read or Socket.write have failed
    SOCKET_ERROR,
    // Server sent CLOSE frame during Ws.read_message()
    SERVER_CLOSE_ERROR,
}

struct Ws {
    Socket socket;
}

// TODO: verify the request status line
// TODO: verify the rest of the headers of the request
// Right now we are only looking for Sec-WebSocket-Key
fn String! parse_sec_websocket_key_from_request(String request)
{
    foreach (header: request.tsplit("\r\n")[1..]) {
        if (header.len == 0) break;
        String[] header_parts = header.tsplit(":", 2);
        if (header_parts.len < 2) return Ws_Error.SERVER_HANDSHAKE_BAD_REQUEST?;
        String key = header_parts[0].trim();
        String value = header_parts[1].trim();

        if (key == "Sec-WebSocket-Key") {
            return value;
        }
    }
    return Ws_Error.SERVER_HANDSHAKE_NO_KEY?;
}

fn void! Ws.server_handshake(ws)
{
    char[1024] buffer;
    usz buffer_size = ws.socket.read(&buffer)!;
    String request = (String)buffer[0:buffer_size];
    String sec_websocket_key = parse_sec_websocket_key_from_request(request)!;

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

    // TODO: the server handshake is literally ignored
    // Right now we are making this assumptions:
    // 1. The server sent the successful handshake
    // 2. Nothing is sent after the handshake so we can distinguish the frames
    // 3. The handshake fits into sizeof(buffer)
    char[1024] buffer;
    usz buffer_size = ws.socket.read(&buffer)!;
    String response = (String)buffer[0:buffer_size];
    io::printfn("Server response: %s", response);
    if (!response.ends_with("\r\n")) {
        return Ws_Error.CLIENT_HANDSHAKE_ERROR?;
    }
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
    ws.socket.read(&header)!;

    uint payload_len = 0;

    // Parse the payload length
    {
        // TODO: do we need to reverse the bytes on a machine with a different endianess than x86?
        char len = pAYLOAD_LEN(header);
        switch (len) {
        case 126: {
            char[2] ext_len = {};
            ws.socket.read(&ext_len)!;

            for (usz i = 0; i < ext_len.len; ++i) {
                payload_len = (payload_len << 8) | ext_len[i];
            }
        }
        break;
        case 127: {
            char[8] ext_len = {};
            ws.socket.read(&ext_len)!;

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
    {
        uint mask = 0;
        bool masked = (bool) mASK(header);

        if (masked) {
            ws.socket.read(((char*)&mask)[:$sizeof(mask)])!;
        }
    }

    // Read the payload
    {
        Ws_Frame *frame = mem::temp_new(Ws_Frame);
        frame.fin = (bool) fIN(header);
        frame.opcode = (Ws_Opcode) oPCODE(header);
        frame.payload = mem::temp_new_array(char, payload_len);

        if (frame.payload.len > 0) {
            // TODO: ws.read_frame does not handle when ws.read didn't read the whole payload
            ws.socket.read(frame.payload)!;
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
