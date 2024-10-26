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
module c3ws;

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
    // Socket.read or Socket.write have failed
    SOCKET_ERROR,
    // Server sent CLOSE frame during Ws.read_message()
    SERVER_CLOSE_ERROR,
}

module c3ws::ws(<Socket>);

import libc;

struct Ws {
    Socket socket;
}

fn void! Ws.client_handshake(ws, ZString host)
{
    DString handshake;
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
    int buffer_size = ws.socket.read(&buffer)!;
    if (buffer_size < 2 || buffer[buffer_size - 2] != '\r' || buffer[buffer_size - 1] != '\n') {
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
        ws.send_frame(payload.len - len == 0, first ? (Ws_Opcode) kind : c3ws::OPCODE_CONT, payload[0:len])!;
        payload = payload[len..];
        first = false;
    }
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
        Ws_Frame *frame = mem::new(Ws_Frame);
        frame.fin = (bool) fIN(header);
        frame.opcode = (Ws_Opcode) oPCODE(header);
        frame.payload = mem::new_array(char, payload_len);

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
    Ws_Message *message = mem::alloc(Ws_Message);
    message.chunks = null;

    while (try frame = ws.read_frame()) {
        if (c3ws::opcode_is_control(frame.opcode)) {
            switch (frame.opcode) {
            case c3ws::OPCODE_CLOSE:
                return Ws_Error.SERVER_CLOSE_ERROR?;
            case c3ws::OPCODE_PING:
                ws.send_frame(true, c3ws::OPCODE_PONG, frame.payload)!;
                break;
            default: {
                // Ignore any other control frames for now
            }
            }
        } else {
            // TODO: ws.read_message does not verify that the message starts with non CONT frame (does it have to start with non-CONT frame)?
            // TODO: ws.read_message does not verify that any non-fin "continuation" frames have the CONT opcode
            if (end == null) {
                end = mem::alloc(Ws_Message_Chunk);
                end.next = null;
                end.payload = frame.payload;
                message.chunks = end;
                message.kind = (Ws_Message_Kind) frame.opcode;
            } else {
                end.next = mem::alloc(Ws_Message_Chunk);
                end.next.next = null;
                end.next.payload = frame.payload;
                end = end.next;
            }

            if (frame.fin) break;
        }
    }

    return message;
}
