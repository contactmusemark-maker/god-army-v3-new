// Service worker: shows push notifications when the app is closed.
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(_){}
  e.waitUntil(self.registration.showNotification(d.title||"God's Army Fitness Centre",{body:d.body||'',icon:'icon-192.png',badge:'icon-192.png'}));
});
self.addEventListener('notificationclick',e=>{
  e.notification.close();
  e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>l.length?l[0].focus():clients.openWindow('./')));
});
