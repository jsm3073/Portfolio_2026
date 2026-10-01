/* Shared navigation and theme; project links use normal browser navigation. */
const motionReduced = window.matchMedia('(prefers-reduced-motion: reduce)');
const clock = document.getElementById('clock');
function updateClock(){
  if(clock) clock.textContent = 'Los Angeles · ' + new Date().toLocaleTimeString('en-US',{hour:'2-digit',minute:'2-digit',hour12:false,timeZone:'America/Los_Angeles'});
}
updateClock(); setInterval(updateClock,60000);
const toggle=document.getElementById('mode-toggle');
function applyMode(dark){
  document.documentElement.classList.toggle('dark',dark);
  toggle.setAttribute('aria-pressed',String(dark));toggle.querySelector('.mode-label').textContent=dark?'Night':'Day';toggle.querySelector('.mode-glyph').textContent=dark?'☾':'☼';
}
applyMode(document.documentElement.classList.contains('dark'));
toggle.addEventListener('click',()=>{const dark=!document.documentElement.classList.contains('dark');applyMode(dark);try{localStorage.setItem('sj-folio-mode',dark?'dark':'light');}catch{}});
const navLinks=[...document.querySelectorAll('.site-nav a')];
navLinks.forEach(link=>link.addEventListener('click',event=>{
  const section=link.hash && link.pathname===location.pathname ? document.querySelector(link.hash) : null;
  if(section){event.preventDefault();history.replaceState(null,'',link.hash);section.scrollIntoView({behavior:motionReduced.matches?'instant':'smooth'});}
}));
if('IntersectionObserver' in window){
  const observer=new IntersectionObserver(entries=>{
    for(const entry of entries)if(entry.isIntersecting){
      navLinks.forEach(link=>{if(link.hash==='#'+entry.target.id)link.setAttribute('aria-current','location');else link.removeAttribute('aria-current');});
    }
  },{rootMargin:'-15% 0px -55% 0px',threshold:0});
  navLinks.forEach(link=>{const section=link.hash && link.pathname===location.pathname ? document.querySelector(link.hash) : null;if(section)observer.observe(section);});
  const hero=document.getElementById('hero');if(hero)observer.observe(hero);
}

const legacyProject=location.hash.match(/^#(project-\d+)-modal$/);if(legacyProject && window.PORTFOLIO_ROUTES?.[legacyProject[1]])location.replace(new URL(window.PORTFOLIO_ROUTES[legacyProject[1]],location.href));
document.querySelectorAll('.about-contents a').forEach(link=>link.addEventListener('click',()=>{
  const target=document.getElementById(link.hash.slice(1));
  if(target?.tagName==='DETAILS')target.open=true;
}));
if(location.hash==='#about-timeline'){
  const timeline=document.getElementById('about-timeline');
  if(timeline)timeline.open=true;
}
function redirectLegacyBiography(){
  if(location.hash==='#biography' && document.getElementById('hero')){
    location.replace(new URL('about.html',location.href));
  }
}
redirectLegacyBiography();
window.addEventListener('hashchange',redirectLegacyBiography);
