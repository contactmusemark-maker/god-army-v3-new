// Sends a Web Push to every device of the notified user. Triggered by a Database Webhook on notifications INSERT.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

Deno.serve(async (req) => {
  if (req.headers.get('x-webhook-secret') !== Deno.env.get('WEBHOOK_SECRET')) return new Response('forbidden', { status: 403 });
  const { record } = await req.json();
  if (!record?.user_id) return new Response('no record', { status: 400 });
  webpush.setVapidDetails(Deno.env.get('VAPID_SUBJECT')!, Deno.env.get('VAPID_PUBLIC')!, Deno.env.get('VAPID_PRIVATE')!);
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data } = await sb.from('push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', record.user_id);
  await Promise.all((data ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ title: record.title, body: record.body ?? '' }));
    } catch (e) {
      if ([404, 410].includes((e as { statusCode?: number }).statusCode ?? 0)) await sb.from('push_subscriptions').delete().eq('id', s.id);
    }
  }));
  return new Response('ok');
});
