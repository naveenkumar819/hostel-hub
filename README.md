# Hostel Hub: deploy guide

Stack: **Supabase** (cloud database + logins + security rules) and **Vercel or Netlify** (public link).
Total time: about 15 minutes. Both have free plans; check their current limits when you sign up.

## 1. Create the database (Supabase)
1. Sign up at supabase.com and click **New project**. Pick a region near you and save the database password.
2. Open **SQL Editor > New query**, paste all of `schema.sql`, and click **Run**. It creates the tables, security rules and 12 starter rooms (delete or edit them later in the app).
3. Open **Authentication > Sign In / Providers > Email**. For the simplest setup, turn **Confirm email** off. If you keep it on, students must click a link in their email before they can log in.
4. Open **Project Settings > API** and copy the **Project URL** and the **anon public** key.

## 2. Connect the website
Open `config.js` and paste the URL and anon key. Never paste the `service_role` key.

## 3. Deploy and get your link
- **Vercel:** vercel.com > Add New > Project. Upload this folder (or push it to GitHub and import it). No build settings are needed; it is a static site.
- **Netlify (easiest):** app.netlify.com/drop, then drag the `hostel-hub` folder onto the page.

You get a public link such as `https://your-hostel.vercel.app`.

Then in Supabase go to **Authentication > URL Configuration** and set **Site URL** to that link (needed for password-reset emails).

## 4. Create the owner account
1. Open your link, click **New student? Request a room**, and sign up with your own email.
2. In Supabase **SQL Editor** run (use your email):
   ```sql
   update public.profiles set role = 'owner', status = 'approved' where email = 'you@example.com';
   ```
3. Log in. You now see the owner dashboard. Share the link with students.

## How it works
- Students request a room, you approve or reject it in **Requests**, and only then can they use the app.
- Security is enforced by the database (row-level security), not the page: a student can only see their own room's complaints and power data, and cannot approve themselves, post notices or see other students' phone numbers.
- Passwords are handled by Supabase Auth (hashed on the server). Students can reset them by email.

## Real power readings
The Power tab takes manual readings. For automatic readings, use smart plugs or energy meters (Shelly, Tuya, or ESP32 + PZEM) that call a small Supabase Edge Function to insert rows into `power_readings` (room_id, reading_date, kwh). That part needs hardware and is not included.

## Good to know
- Supabase free projects may pause after a period of inactivity; check their current policy.
- Back up your data from Supabase (Database > Backups) before making big changes.
