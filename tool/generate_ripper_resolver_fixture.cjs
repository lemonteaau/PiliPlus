// Run with the Bilibili-thread-ripper checkout at documented commit as argv[2].
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');
const root = process.argv[2];
let now = 100000;
Date.now = () => now;
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
  record('sample', [urls.at(-1), 1500000]);
  record('speed', [urls.at(-1)]);
  steps.push({op:'advance',args:[90001]});
  now += 90001;
  record('speed', [urls.at(-1)]);
  record('rangeCandidates');
  fixtures.push({mode, representation, urls, steps});
}
fs.writeFileSync('test/fixtures/ripper_resolver.json', JSON.stringify(fixtures,null,2)+'\n');

// Expose the unchanged upstream assignment function only in this test VM.
const source = fs.readFileSync(path.join(root, 'src/idm-downloader.js'), 'utf8');
const marker = 'return Object.freeze({ downloadRange, applySettings, getConcurrency: () => semaphore.limit });';
if (!source.includes(marker)) throw new Error('Upstream downloader shape changed: review fixture generator');
vm.runInThisContext(source.replace(marker, 'return { assignPrimaries };'));
const downloader = globalThis.__BILI_IDM_DOWNLOADER_FACTORY__.createDownloader({getSettings:()=>({concurrency:8})});
const weighted = [];
for (const speeds of [[0,0,0,0], [1200000,600000,10000,0], [900000,300000,0,0], [100000,100000,100000,100000]]) {
  const urls = speeds.map((_,i)=>`https://node${i}.bilivideo.com/v.m4s`);
  const resolver = {speed: url => speeds[urls.indexOf(url)]};
  const steps = [2,2,2,2,8,16].map(count=>({count,expected:downloader.assignPrimaries(urls,resolver,count)}));
  weighted.push({urls,speeds,steps});
}
fs.writeFileSync('test/fixtures/ripper_assignments.json', JSON.stringify(weighted,null,2)+'\n');

let clock = 5000;
const auto = globalThis.__BILI_IDM_DOWNLOADER_FACTORY__.createAutoConcurrency({now:()=>clock});
const autoSteps = [];
function act(op, args=[], advance=0) {
  clock += advance;
  auto[op](...args);
  autoSteps.push({at:clock,op,args,threads:auto.threads()});
}
function flow(bps, duration) {
  act('demand',[auto.threads(), auto.threads(), 12]);
  for (let i=0;i<duration;i+=250) {
    act('activity',[],250);
    act('delivered',[bps/4]);
  }
}
flow(1000000,5000);
act('stall');
flow(950000,11000); // Fruitless trial returns to eight and rests twelve.
act('stall',[],3000); // A stall can skip the resting level.
flow(1500000,11000);
act('pushback',[429]);
act('stall',[],3000); // A refusal cannot be skipped.
act('stall',[],180001);
act('newSession');
for (let i=0;i<12;i++) {
  act('activity',[],250);
  act('buffer',[4-i*.1,true]);
}
fs.writeFileSync('test/fixtures/ripper_auto.json',JSON.stringify(autoSteps,null,2)+'\n');
