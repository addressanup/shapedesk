import { initDesktop } from './desktop.js';
import { initProPlan, initSortDesk } from './sortdesk.js';

const views = [...document.querySelectorAll('main > .view')];
const nav = [...document.querySelectorAll('[data-route]')];
const select = document.getElementById('view-select');
const initialized = new Set();
const aliases = { how:'top', 'whats-new':'storage', 'local-sorting':'ai-sort', install:'help', faq:'help', privacy:'help', 'help-coupons':'help' };
let active = '';

function route(focus = false) {
  let hash;
  try { hash = decodeURIComponent(location.hash.slice(1)); } catch { hash = ''; }
  const id = aliases[hash] || hash || 'top';
  const next = views.find(v => v.id === id) || views[0];
  if (active === 'watch' && next.id !== active) document.getElementById('demo-video').pause();
  views.forEach(v => { v.hidden = v !== next; });
  nav.forEach(a => { if(a.dataset.route === next.id) a.setAttribute('aria-current','page'); else a.removeAttribute('aria-current'); });
  select.value = next.id;
  active = next.id;
  if (!initialized.has(active)) {
    if(active === 'top') initDesktop();
    if(active === 'ai-sort') initSortDesk();
    initialized.add(active);
  }
  if (hash === 'privacy' || hash === 'faq' || hash === 'help-coupons') {
    showHelp('questions');
    showAnswer(hash === 'help-coupons' ? 5 : 0);
  } else if(hash === 'install') showHelp('install');
  if(focus) next.querySelector('h1, h2')?.focus({preventScroll:true});
}
select.addEventListener('change', () => { location.hash = select.value; });
window.addEventListener('hashchange', () => route(true));
// Repeated links to the active view still resolve aliases (e.g. Privacy).
document.querySelectorAll('a[href^="#"]').forEach(a => a.addEventListener('click', e => {
  if(a.hash === '#content') { e.preventDefault(); document.getElementById('content').focus({preventScroll:true}); return; }
  if(a.hash === location.hash) route(true);
}));

function tabGroup(selector, activate) {
  const buttons = [...document.querySelectorAll(selector)];
  buttons.forEach((b,i) => {
    b.addEventListener('click', () => activate(b));
    b.addEventListener('keydown', e => {
      let n = i;
      if(e.key === 'ArrowRight') n=(i+1)%buttons.length;
      else if(e.key === 'ArrowLeft') n=(i+buttons.length-1)%buttons.length;
      else if(e.key === 'Home') n=0;
      else if(e.key === 'End') n=buttons.length-1;
      else return;
      e.preventDefault(); activate(buttons[n]); buttons[n].focus();
    });
  });
}
tabGroup('[data-storage]', b => {
  document.querySelectorAll('[data-storage]').forEach(t => { const on=t===b; t.setAttribute('aria-selected',String(on)); t.tabIndex=on?0:-1; });
  document.querySelectorAll('.storage-pane').forEach((p,i) => { p.hidden=i!==Number(b.dataset.storage); });
});
tabGroup('[data-plan]', b => {
  document.querySelectorAll('[data-plan]').forEach(t => { const on=t===b; t.setAttribute('aria-selected',String(on)); t.tabIndex=on?0:-1; });
  document.querySelector('.plan-layout').dataset.planActive=b.dataset.plan;
});
const settingDetails = [
 ['READY WHEN YOU ARE','Turn on Open ShapeDesk at login in the app. It will be waiting in your menu bar when you start your Mac.'],
 ['CARRY ON WITH YOUR DAY','When the panel is closed, a notification tells you when a sort, undo or duplicate move finishes. Click it to see the result. You can turn notifications off.'],
 ['SAVE YOUR AI CHECKS','Screenshots, code, documents and other obvious files sort on your Mac by default. Only the remaining files go to AI. Local sorting is included with Pro.'],
 ['YOU CHOOSE WHEN TO UPDATE','Automatic checks show a link when a new release is available. They never download or install it. Choose Check now in Settings anytime.'],
];
document.querySelectorAll('[data-setting]').forEach(b => b.addEventListener('click', () => {
  document.querySelectorAll('[data-setting]').forEach(t => t.setAttribute('aria-pressed',String(t===b)));
  const [title,detail]=settingDetails[Number(b.dataset.setting)];
  document.querySelector('.setting-detail .eyebrow').textContent=title;
  document.getElementById('setting-description').textContent=detail;
}));
function showHelp(which) {
  document.querySelectorAll('[data-help]').forEach(b=>{const on=b.dataset.help===which;b.setAttribute('aria-selected',String(on));b.tabIndex=on?0:-1;});
  document.getElementById('install-guide').hidden=which!=='install';
  document.getElementById('question-guide').hidden=which!=='questions';
}
tabGroup('[data-help]', b=>showHelp(b.dataset.help));
let step=0;
function showStep(n) {
  step=Math.max(0,Math.min(4,n));
  document.querySelectorAll('[data-step]').forEach(b=>{ if(Number(b.dataset.step)===step)b.setAttribute('aria-current','step');else b.removeAttribute('aria-current'); });
  document.querySelectorAll('[data-step-page]').forEach(p=>{p.hidden=Number(p.dataset.stepPage)!==step;});
  document.getElementById('step-counter').textContent=`${step+1} of 5`;
  document.getElementById('step-prev').disabled=step===0;
  document.getElementById('step-next').disabled=step===4;
}
document.querySelectorAll('[data-step]').forEach(b=>b.addEventListener('click',()=>showStep(Number(b.dataset.step))));
document.getElementById('step-prev').addEventListener('click',()=>showStep(step-1));
document.getElementById('step-next').addEventListener('click',()=>showStep(step+1));
function showAnswer(n) {
  document.getElementById('question-select').value=String(n);
  document.querySelectorAll('[data-answer]').forEach(p=>{p.hidden=Number(p.dataset.answer)!==Number(n);});
}
document.getElementById('question-select').addEventListener('change',e=>showAnswer(e.target.value));
document.querySelectorAll('[data-time]').forEach(b=>b.addEventListener('click',()=>{
  const video=document.getElementById('demo-video'); video.currentTime=Number(b.dataset.time); video.play().catch(()=>{});
}));
route();
initProPlan();
