// SPDX-License-Identifier: GPL-3.0-only
// One request per process. Secrets use stdin/stdout, never command-line arguments.
'use strict';
const readline = require('node:readline');
const signer = require('./signer.cjs');
const player = require('./player_signer.cjs');
readline.createInterface({ input: process.stdin, terminal: false }).once('line', line => {
  try {
    const input = JSON.parse(line);
    if (!input.device || !/^[1-9]\d{15,19}$/.test(input.device.device_id) || !/^[1-9]\d{15,19}$/.test(input.device.iid)) throw Error('Invalid visitor identity');
    let signed;
    if (input.operation === 'search') {
      const allowed = new Set(['query','tab_type','count','bookshelf_search_plan','user_is_login','offset','search_id','passback']);
      if (!input.query || typeof input.query.query !== 'string' || [...input.query.query].length < 1 || [...input.query.query].length > 80) throw Error('Invalid search');
      for (const [key,value] of Object.entries(input.query)) {
        if (!allowed.has(key) || typeof value !== 'string' || value.length > 2048 || /[\x00-\x1f]/.test(value)) throw Error('Invalid search field');
      }
      signed = signer.signSearch(input.query, input.device);
    } else {
      if (![undefined,'playbackFallback'].includes(input.operation) || typeof input.body !== 'string' || input.body.length > 65536) throw Error('Invalid request');
      const ids = JSON.parse(input.body)?.mixed_video_id_map?.['1004'];
      if (!Array.isArray(ids) || ids.length !== 1 || !/^\d{1,32}$/.test(ids[0])) throw Error('Invalid episode');
      signed = player.sign(ids[0], input.device, {body: input.operation === 'playbackFallback' ? undefined : input.body});
    }
    process.stdout.write(JSON.stringify({url:signed.url, headers:signed.headers, body:signed.body.toString('utf8'), method:signed.method ?? 'GET'}));
  } catch (_) { process.stderr.write('Protocol signing failed'); process.exitCode = 1; }
});
