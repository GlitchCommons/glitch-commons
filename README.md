# Glitch Commons — launch guide

Your site is two files:

- **index.html** is the whole website.
- **setup.sql** is a one-time script that builds your database in Supabase.

Follow these steps in order. Allow about 30 minutes.

---

## 1. Build the database (Supabase)

1. Open your project at supabase.com.
2. In the left sidebar, click **SQL Editor**, then **New query**.
3. Open `setup.sql`, copy everything, paste it into the editor, and click **Run**.
4. You should see "Success. No rows returned." It's safe to run again if anything hiccups.

This creates the tables for profiles, posts, replies, resonance, chat and private messages, plus image storage and the security rules that keep private messages private.

## 2. Put the code on GitHub

1. On github.com, click **+** (top right) → **New repository**.
2. Name it `glitch-commons`. Public or private both work. Click **Create repository**.
3. On the next screen, click **uploading an existing file**.
4. Drag in `index.html`, `setup.sql` and `README.md`, then click **Commit changes**.

## 3. Put the site online (Netlify)

1. On netlify.com, click **Add new site** → **Import an existing project** → **GitHub**.
2. Allow Netlify to access your `glitch-commons` repository and select it.
3. Leave **Build command** empty and set **Publish directory** to `.` (a single dot), or leave it empty.
4. Click **Deploy**. In a minute you'll get an address like `random-name-123.netlify.app`.
5. Optional: under **Site configuration → Change site name**, rename it to something like `glitch-commons` so the address becomes `glitch-commons.netlify.app`.

## 4. Tell Supabase your site's address

Sign-up confirmation and password reset emails need to link back to your site.

1. In Supabase, go to **Authentication → URL Configuration**.
2. Set **Site URL** to your Netlify address, for example `https://glitch-commons.netlify.app`.
3. Under **Redirect URLs**, click **Add URL** and add the same address.
4. Save.

## 5. Create your account and make yourself the admin

1. Visit your site and click **Join free**. Use your real email.
2. Click the confirmation link in the email (check spam). You'll land back on the site and confirm your handle.
3. In Supabase **SQL Editor**, run this with your email filled in:

   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```

As admin, you can delete any post, reply or Lounge message. Nobody can read private messages except the two people in them, including you.

## 6. Before you invite lots of people: email sending

Supabase's built-in email sender only allows a handful of emails per hour. That's fine for testing with friends, but sign-ups will stall at launch. Before opening the doors:

- Set up a free email-sending service such as Resend, then connect it in Supabase under **Authentication → Emails → SMTP Settings**.
- Or, for a small private test only, turn off **Confirm email** under **Authentication → Sign In / Providers → Email**. Turn it back on before going public.

## Database updates

Some new features come with an update script. Run each one once, in number order, after `setup.sql`:

| File | Adds |
|---|---|
| `update-01-votes-notifications.sql` | Upvotes/downvotes and the notification bell |

If you ever rebuild the database from scratch, run `setup.sql` first, then each update file in order.

## Making changes later

- Edit `index.html` on GitHub (open the file, click the pencil icon, **Commit changes**). Netlify republishes automatically in about a minute.
- Or bring `index.html` to Claude, describe the change, and upload the updated file to GitHub the same way.
- Your members' posts, profiles and images live in Supabase, so updating the website never erases them.

## Adding your own domain (later)

1. Buy a domain (for example from Cloudflare, Namecheap or Porkbun).
2. In Netlify: **Domain management → Add a domain** and follow its instructions.
3. Update the Supabase **Site URL** and **Redirect URLs** (step 4) to the new domain.

## Your keys

The Project URL and publishable key are inside `index.html`. They're designed to be public. **Never** put your Supabase *secret* key or database password in the website, on GitHub, or in a chat.
