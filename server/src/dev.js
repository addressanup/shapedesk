import { createServer } from 'node:http';
import handler from './runtime.js';
createServer(handler).listen(Number(process.env.PORT ?? 8787), '127.0.0.1');
