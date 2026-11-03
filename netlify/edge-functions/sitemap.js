// Netlify Edge Function: glitchcommons.com/sitemap.xml
//
// Builds a fresh list of every public page (posts, Vault cases, profiles, topics
// and answered daily questions) straight from Supabase, so Google finds new
// content without anyone updating a file. Cached for an hour at a time.

import { ORIGIN, REALMS, db, realmSlug, postPath, casePath, profilePath } from "../shared/site.js";

const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]));
const day = iso => String(iso).slice(0, 10);

// Supabase returns at most 1,000 rows per request, so read in pages.
async function all(path, max = 45000) {
  const out = [];
  for (let offset = 0; offset < max; offset += 1000) {
    const rows = await db(`${path}&limit=1000&offset=${offset}`);
    if (!rows || !rows.length) break;
    out.push(...rows);
    if (rows.length < 1000) break;
  }
  return out;
}

export default async () => {
  const [posts, cases, profiles, answered] = await Promise.all([
    all("posts?select=id,title,created_at&order=created_at.desc"),
    all("vault_cases?select=case_no,created_at&order=case_no.desc"),
    all("profiles?select=handle,created_at&order=created_at.desc"),
    all("posts?select=prompt_day&prompt_day=not.is.null&order=prompt_day.desc"),
  ]);
  const latest = list => list.length ? day(list[0].created_at) : null;
  const urls = [
    { loc: "/", lastmod: latest(posts) },
    { loc: "/vault", lastmod: latest(cases) },
    ...REALMS.map(([id]) => ({ loc: "/topics/" + realmSlug(id) })),
    ...[...new Set(answered.map(r => r.prompt_day))].map(d => ({ loc: "/question/" + d, lastmod: d })),
    ...posts.map(p => ({ loc: postPath(p.id, p.title), lastmod: day(p.created_at) })),
    ...cases.map(c => ({ loc: casePath(c.case_no), lastmod: day(c.created_at) })),
    ...profiles.map(p => ({ loc: profilePath(p.handle), lastmod: day(p.created_at) })),
  ];
  const xml = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
    urls.map(u => `  <url><loc>${esc(ORIGIN + u.loc)}</loc>${u.lastmod ? `<lastmod>${esc(u.lastmod)}</lastmod>` : ""}</url>`).join("\n") +
    "\n</urlset>\n";
  return new Response(xml, {
    headers: {
      "content-type": "application/xml; charset=utf-8",
      "cache-control": "public, max-age=0, must-revalidate",
      "netlify-cdn-cache-control": "public, s-maxage=3600",
    },
  });
};

export const config = { path: "/sitemap.xml", cache: "manual" };
