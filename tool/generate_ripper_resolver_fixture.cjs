// Run with the Bilibili-thread-ripper checkout at documented commit as argv[2].
const path = require('node:path');
const fs = require('node:fs');
const root = process.argv[2];
require(path.join(root, 'src/range-core.js'));
require(path.join(root, 'src/cdn-resolver.js'));
const factory = globalThis.__BILI_CDN_RESOLVER_FACTORY__;
const representation = {
  baseUrl: 'https://video.akamaized.net/v.m4s?sign=a%2Bb',
  backupUrl: ['https://upos-sz-mirroraliov.bilivideo.com/v.m4s?sign=a%2Bb'],
};
const fixtures = [];
for (const mode of ['overseas','mainland']) {
  const bans = factory.createBanList();
  const resolver = factory.createResolver(representation, () => mode, bans);
  const urls = factory.representationUrls(representation, mode);
  const steps = [];
  function record(op, args=[]) {
    const result = resolver[op](...args);
    steps.push({op,args,...(result === undefined ? {} : {expected:result})});
  }
  record('startupCandidates');
  record('rangeCandidates');
  record('success', [urls.at(-1), 900000]);
  record('success', [urls[0], 400000]);
  record('rescueCandidates');
  for(let i=0;i<7;i++) record('rangeCandidates');
  for(let i=0;i<5;i++) record('ordered',[i]);
  record('failure',[urls[0], {status:403}, 0]);
  record('failure',[urls[0], {status:403}, 0]);
  record('rescueCandidates');
  record('rangeCandidates');
  record('startupCandidates');
  fixtures.push({mode, representation, urls, steps});
}
fs.writeFileSync('test/fixtures/ripper_resolver.json', JSON.stringify(fixtures,null,2)+'\n');
