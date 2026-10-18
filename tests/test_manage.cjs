const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync('scripts/manage.html','utf8');
class Element {
  constructor(id='') { this.id=id; this.value=''; this.checked=false; this.disabled=false; this.hidden=false; this.textContent=''; this.children=[]; this.attrs={}; this.dataset={}; this.style={}; this.parent={hidden:false}; this.listeners={}; this.classList={toggle(){},add(){},remove(){}}; }
  addEventListener(name,fn) { this.listeners[name]=fn; }
  setAttribute(name,value) { this.attrs[name]=value; }
  append(...els) { this.children.push(...els); }
  replaceChildren(...els) { this.children=els; }
  closest() { return this.parent; }
  querySelectorAll() { return this.id === 'settings' ? settingIDs.map(id=>elements[id]) : this.id === 'advanced-content' ? advancedIDs.map(id=>elements[id]) : []; }
  get selectedOptions() { return this.selection || [{value:this.value,textContent:this.value}]; }
}
const elements = Object.fromEntries([...html.matchAll(/\bid="([^"]+)"/g)].map(m=>[m[1],new Element(m[1])]));
const advancedIDs=['storage-backend','version-policy','letsencrypt','le-email','devops-components','autodestroy-at','monitoring','rebuild-image','letsencrypt-prod'];
const settingIDs=['profile','region','release','duration','lab-topology','lab-tier','masters','workers','master-type','worker-type','autodestroy','advanced-toggle',...advancedIDs];
const defaults={cluster:'legacy',profile:'2',duration:'8','lab-topology':'1x1','lab-tier':'low',masters:'3',workers:'3','storage-backend':'local','version-policy':'n-2'};
for(const [key,value] of Object.entries(defaults))elements[key].value=value;
elements.autodestroy.checked=true;
elements['devops-components'].selection=[];
let op='deploy';
const buttons=['1','2','3','4'].map(value=>{const e=new Element();e.dataset.profile=value;return e;});
const document={getElementById:id=>{assert.ok(elements[id],`Unknown ID ${id}`);return elements[id];},querySelector:()=>({value:op}),querySelectorAll:()=>buttons,createElement:()=>new Element(),createElementNS:()=>new Element()};
const context=vm.createContext({document,URLSearchParams,location:{search:''},setInterval(){},history:{replaceState(){}},Option:class extends Element{constructor(text,value){super();this.textContent=text;this.value=value;}},fetch(){throw Error('Unexpected network call in form test');}});
vm.runInContext(html.split('<script>')[1].split('</script>')[0],context);
const run = code => vm.runInContext(code,context);
const options = () => JSON.parse(JSON.stringify(run('options()')));
assert.deepEqual(options(),{profile:'2',duration:'8','no-autodestroy':false});
assert.equal(elements.start.disabled,true);
assert.equal(elements['advanced-content'].hidden,true);
assert.ok(advancedIDs.every(id=>elements[id].disabled));
assert.equal(elements.topology.children[0].attrs['aria-label'],'Planned topology: 3 control-plane nodes and 3 workers');
elements.profile.value='3';elements['lab-topology'].value='1x0';run('render()');
assert.equal(elements.topology.children[0].attrs['aria-label'],'Planned topology: 1 control-plane nodes and 0 workers');
assert.equal(elements.lab.hidden,false);assert.equal(elements.manual.hidden,true);assert.equal(elements.manual.disabled,true);
assert.equal(options()['lab-topology'],'1x0');assert.ok(!('masters' in options()));
elements['advanced-toggle'].checked=true;elements.letsencrypt.value='staging';elements['letsencrypt-prod'].checked=true;elements['le-email'].value='ops@example.com';elements.monitoring.checked=true;elements['devops-components'].selection=[{value:'argocd'},{value:'loki-operator'}];elements['autodestroy-at'].value='90m';run('render()');
assert.equal(options().letsencrypt,true);assert.equal(options()['letsencrypt-prod'],true);assert.equal(options()['devops-components'],'argocd,loki-operator');assert.equal(options()['autodestroy-at'],'90m');
assert.ok(elements.command.textContent.includes('--letsencrypt --letsencrypt-prod --le-email ops@example.com'));
assert.ok(!elements.command.textContent.includes('--no-admin'));
elements.letsencrypt.value='';elements.autodestroy.checked=false;run('render()');
assert.ok(!('letsencrypt-prod' in options()));assert.ok(!('le-email' in options()));assert.ok(!('autodestroy-at' in options()));assert.equal(elements['le-email'].disabled,true);
elements['advanced-toggle'].checked=false;run('render()');assert.ok(!('devops-components' in options()));
elements.cluster.value='dev';run('render()');assert.deepEqual(options(),{});assert.equal(elements.settings.hidden,true);assert.equal(elements.command.textContent,'./deploy-okd.sh --yes --cluster dev');assert.equal(elements.topology.children[0].textContent,'Topology is managed by the selected cluster YAML.');
elements.cluster.value='legacy';op='resume';run('render()');assert.deepEqual(options(),{});assert.equal(elements.command.textContent,'./deploy-okd.sh --yes --resume');
op='destroy';run('unlocked=true; busy=false');elements.confirm.value='destroy legacy';run('render()');assert.equal(elements.start.disabled,false);assert.equal(elements.command.textContent,'./destroy-okd.sh --yes');assert.equal(elements.settings.hidden,true);
elements.confirm.value='deploy legacy';run('render()');assert.equal(elements.start.disabled,true);
op='deploy';elements.profile.value='4';elements.workers.value='12';elements.region.value='<img src=x onerror=alert(1)>';run('render()');assert.equal(elements.topology.children[0].attrs['aria-label'],'Planned topology: 3 control-plane nodes and 12 workers');assert.ok(elements.summary.children.some(row=>row.children.some(child=>child.textContent.includes('<img'))));
console.log('Form checks passed: profiles, topology, hidden fields, certificate booleans, command preview, pinned clusters, resume/destroy and confirmation.');
