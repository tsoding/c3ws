import { WebSocketServer } from 'ws';

const SERVER_PORT = 9001;
const wss = new WebSocketServer({ port: SERVER_PORT });

wss.on("connection", (ws, req) => {
    ws.binaryType = 'arraybuffer';

    ws.addEventListener("message", (event) => {
        if (event.data instanceof ArrayBuffer) {
            console.log(`Recieved binary message of ${event.data.byteLength} bytes`);
        } else {
            console.log(`Recieved text message of ${event.data.length} characters`);
        }
        ws.send(event.data);
        ws.close();
    })
    ws.addEventListener("error", () => {
        console.log("ERROR");
    })
});
console.log(`Listening to ws://localhost:${SERVER_PORT}`)
