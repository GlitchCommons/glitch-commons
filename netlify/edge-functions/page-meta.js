// Netlify Edge Function: page previews for search engines and link sharing.
//
// Before a post, Vault case, profile, topic or daily question page is sent, this
// looks the page up in Supabase and writes its own title, description, preview
// image and structured data into the HTML, plus a readable copy of the content.
// Google, Facebook, X and iMessage can then see each page without running the
// site's code. The site's code takes over normally once it loads.
//
// If anything goes wrong, the page is served exactly as before (onError: "bypass").

import {
  ORIGIN, SITE, REALMS, db, realmName, realmSlug, caseTypeName, postPath, casePath, profilePath,
  caseNo, imageUrl, isImagePath, promptFor,
} from "../shared/site.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HANDLE = /^[A-Za-z0-9_.-]{2,32}$/;
const DEFAULT_IMAGE = ORIGIN + "/og-default.png";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const clip = (t, n = 155) => { t = String(t || "").replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n - 1).replace(/\s+\S*$/, "") + "…" : t };
const paras = t => String(t || "").split(/\n+/).map(x => x.trim()).filter(Boolean).map(x => `<p>${esc(x)}</p>`).join("");
const fmtDate = iso => new Date(iso).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" });
const linkList = items => items.length ? `<ul class="pr-list">${items.join("")}</ul>` : "";
const back = (href, text) => `<a class="back" href="${href}">${esc(text)}</a>`;

function notFound(what) {
  return { status: 404, title: `${what} not found · ${SITE}`, desc: "", robots: "noindex", canonical: null, content: null };
}

// ---------- each kind of page ----------

async function postPage(id) {
  const rows = await db(`posts?id=eq.${id}&select=id,title,body,images,realm,created_at,score,prompt_day,profiles(handle),replies(body,created_at,profiles(handle))&replies.order=created_at.asc&replies.limit=30`);
  if (rows === null) return null;
  const p = rows[0];
  if (!p) return notFound("Post");
  const who = (p.profiles && p.profiles.handle) || "someone";
  const reps = p.replies || [];
  const imgs = (p.images || []).filter(isImagePath).slice(0, 4);
  const url = ORIGIN + postPath(p.id, p.title);
  const content = `<div class="profile prerender">${back("/", "← Back to the ideas")}
<article class="post">
<div class="meta"><a class="tag" href="/topics/${realmSlug(p.realm)}">${esc(realmName(p.realm))}</a> <a class="who" href="${profilePath(who)}">@${esc(who)}</a> <span>${fmtDate(p.created_at)}</span></div>
<h1 class="post-title">${esc(p.title)}</h1>
<div class="body">${paras(p.body)}</div>
${imgs.map(i => `<img class="pr-img" src="${esc(imageUrl(i))}" alt="Photo attached to this idea" loading="lazy">`).join("")}
<p class="meta">${Math.max(0, p.score || 0)} points · ${reps.length} ${reps.length === 1 ? "reply" : "replies"}</p>
${reps.length ? `<section class="thread"><h2 class="pr-h2">Replies</h2>${reps.map(r => `<div class="reply"><div class="meta">@${esc((r.profiles && r.profiles.handle) || "someone")} · ${fmtDate(r.created_at)}</div>${paras(r.body)}</div>`).join("")}</section>` : ""}
</article></div>`;
  return {
    title: `${p.title} · ${SITE}`, desc: clip(p.body || p.title), canonical: url,
    image: imgs[0] ? imageUrl(imgs[0]) : null, type: "article", content,
    jsonld: {
      "@context": "https://schema.org", "@type": "DiscussionForumPosting",
      headline: p.title, text: p.body || p.title, url, datePublished: p.created_at,
      author: { "@type": "Person", name: who, url: ORIGIN + profilePath(who) },
      ...(imgs[0] ? { image: imageUrl(imgs[0]) } : {}),
      interactionStatistic: [
        { "@type": "InteractionCounter", interactionType: "https://schema.org/LikeAction", userInteractionCount: Math.max(0, p.score || 0) },
        { "@type": "InteractionCounter", interactionType: "https://schema.org/CommentAction", userInteractionCount: reps.length },
      ],
      comment: reps.map(r => ({ "@type": "Comment", text: r.body, datePublished: r.created_at, author: { "@type": "Person", name: (r.profiles && r.profiles.handle) || "someone" } })),
    },
  };
}

async function casePage(no) {
  const rows = await db(`vault_cases?case_no=eq.${no}&select=case_no,type,title,account,happened_on,witnessed,ruled_out,images,video_url,metoo_count,created_at,profiles(handle)`);
  if (rows === null) return null;
  const c = rows[0];
  if (!c) return notFound("Case");
  const who = (c.profiles && c.profiles.handle) || "someone";
  const imgs = (c.images || []).filter(isImagePath).slice(0, 20);
  const url = ORIGIN + casePath(c.case_no);
  const metoo = c.metoo_count === 1 ? "1 person said “this happened to me too”" : `${c.metoo_count || 0} people said “this happened to me too”`;
  const content = `<div class="profile prerender">${back("/vault", "← Back to the Vault")}
<article class="post case-full">
<div class="case-top"><span class="case-no big">${caseNo(c.case_no)}</span> <span class="tag">${esc(caseTypeName(c.type))}</span></div>
<h1 class="case-title">${esc(c.title)}</h1>
<dl class="facts"><dt>When it happened</dt><dd>${c.happened_on ? fmtDate(c.happened_on + "T00:00:00Z") : "Not given"}</dd>
<dt>Witnesses</dt><dd>${c.witnessed === "others" ? "Others were there too" : "Just me"}</dd>
<dt>Logged by</dt><dd><a class="who" href="${profilePath(who)}">@${esc(who)}</a> · ${fmtDate(c.created_at)}</dd></dl>
<h2 class="pr-h4">What happened</h2><div class="body">${paras(c.account)}</div>
${c.ruled_out ? `<h2 class="pr-h4">What's been ruled out</h2><div class="body">${paras(c.ruled_out)}</div>` : ""}
${imgs.map((i, n) => `<img class="pr-img" src="${esc(imageUrl(i))}" alt="Evidence photo ${n + 1} for ${esc(caseNo(c.case_no))}" loading="lazy">`).join("")}
<p class="metoo-count">${esc(metoo)}</p>
</article></div>`;
  return {
    title: `${c.title} · ${caseNo(c.case_no)} · The Vault`, desc: clip(c.account), canonical: url,
    image: imgs[0] ? imageUrl(imgs[0]) : null, type: "article", content,
    jsonld: {
      "@context": "https://schema.org", "@type": "DiscussionForumPosting",
      headline: `${caseNo(c.case_no)}: ${c.title}`, text: c.account, url, datePublished: c.created_at,
      author: { "@type": "Person", name: who, url: ORIGIN + profilePath(who) },
      ...(imgs.length ? { image: imgs.slice(0, 5).map(imageUrl) } : {}),
      interactionStatistic: [{ "@type": "InteractionCounter", interactionType: "https://schema.org/AgreeAction", userInteractionCount: c.metoo_count || 0 }],
    },
  };
}

async function profilePage(arg) {
  let rows;
  if (UUID.test(arg)) rows = await db(`profiles?id=eq.${arg}&select=id,handle,path,bio,show_posts,created_at`);
  else if (HANDLE.test(arg)) rows = await db(`profiles?handle=ilike.${encodeURIComponent(arg)}&select=id,handle,path,bio,show_posts,created_at`);
  else return notFound("Profile");
  if (rows === null) return null;
  const p = (rows || []).find(x => UUID.test(arg) ? x.id === arg : x.handle.toLowerCase() === arg.toLowerCase());
  if (!p) return notFound("Profile");
  let list = "";
  if (p.show_posts !== false) {
    const [posts, cases] = await Promise.all([
      db(`posts?author_id=eq.${p.id}&select=id,title&order=created_at.desc&limit=30`),
      db(`vault_cases?author_id=eq.${p.id}&select=case_no,title&order=case_no.desc&limit=30`),
    ]);
    if (posts && posts.length) list += `<h2 class="pr-h2">Ideas</h2>` + linkList(posts.map(x => `<li><a href="${postPath(x.id, x.title)}">${esc(x.title)}</a></li>`));
    if (cases && cases.length) list += `<h2 class="pr-h2">Vault cases</h2>` + linkList(cases.map(x => `<li><a href="${casePath(x.case_no)}">${caseNo(x.case_no)} · ${esc(x.title)}</a></li>`));
  }
  const url = ORIGIN + profilePath(p.handle);
  const content = `<div class="profile prerender">${back("/", "← Back to the ideas")}
<div class="phead"><div class="info"><h1 class="pr-name">@${esc(p.handle)}</h1>${p.path ? `<div class="path">${esc(p.path)}</div>` : ""}${p.bio ? `<div class="bio">${paras(p.bio)}</div>` : ""}
<div class="pstats">Joined ${fmtDate(p.created_at)}</div></div></div>${list}</div>`;
  return {
    title: `@${p.handle} · ${SITE}`, desc: clip(p.bio || `${p.handle} explores the ideas the mainstream won't touch on Glitch Commons.`),
    canonical: url, type: "profile", content,
    jsonld: { "@context": "https://schema.org", "@type": "ProfilePage", dateCreated: p.created_at, url,
      mainEntity: { "@type": "Person", name: p.handle, alternateName: "@" + p.handle, ...(p.bio ? { description: p.bio } : {}), url } },
  };
}

async function topicPage(slug) {
  const r = REALMS.find(x => realmSlug(x[0]) === slug);
  if (!r) return notFound("Topic");
  const posts = await db(`posts?realm=eq.${r[0]}&select=id,title,body,score&order=score.desc,created_at.desc&limit=40`);
  if (posts === null) return null;
  const name = r[1];
  const desc = `Ideas and first-hand experiences about ${name.toLowerCase()}: the questions the mainstream won't touch, voted up by the Glitch Commons community.`;
  const content = `<div class="profile prerender">${back("/", "← All topics")}<h1 class="pr-name">${esc(name)}</h1><p>${esc(desc)}</p>
${posts.length ? linkList(posts.map(x => `<li><a href="${postPath(x.id, x.title)}">${esc(x.title)}</a>${x.body ? `<p>${esc(clip(x.body, 140))}</p>` : ""}</li>`)) : "<p>No ideas posted in this topic yet.</p>"}</div>`;
  return { title: `${name} · ${SITE}`, desc, canonical: ORIGIN + "/topics/" + slug, content, robots: posts.length ? null : "noindex" };
}

async function questionPage(date) {
  const t = Date.parse(date + "T00:00:00Z");
  if (!t || t < Date.UTC(2026, 9, 26) || t > Date.now() + 864e5) return notFound("Question");
  const q = promptFor(date);
  const posts = await db(`posts?prompt_day=eq.${date}&select=id,title,body,score&order=score.desc,created_at.desc&limit=50`);
  if (posts === null) return null;
  const content = `<div class="profile prerender">${back("/", "← Back to the ideas")}<div class="eyebrow">Forbidden question for ${fmtDate(date + "T00:00:00Z")}</div><h1 class="pr-name">${esc(q)}</h1>
${posts.length ? `<h2 class="pr-h2">${posts.length} ${posts.length === 1 ? "answer" : "answers"}</h2>` + linkList(posts.map(x => `<li><a href="${postPath(x.id, x.title)}">${esc(x.title)}</a>${x.body ? `<p>${esc(clip(x.body, 140))}</p>` : ""}</li>`)) : "<p>No answers yet.</p>"}</div>`;
  return { title: `“${q}” · Answers · ${SITE}`, desc: clip("Glitch Commons members answer the forbidden question: " + q), canonical: ORIGIN + "/question/" + date, content, robots: posts.length ? null : "noindex" };
}

async function vaultPage() {
  const cases = await db(`vault_cases?select=case_no,title,account&order=case_no.desc&limit=60`);
  if (cases === null) return null;
  const desc = "First-hand evidence of synchronicities, glitches, sightings and premonitions, logged case by case by the Glitch Commons community.";
  const content = `<div class="profile prerender">${back("/", "← Back to the ideas")}<div class="eyebrow">Evidence archive</div><h1 class="pr-name">The Vault</h1><p>${esc(desc)}</p>
${linkList(cases.map(c => `<li><a href="${casePath(c.case_no)}">${caseNo(c.case_no)} · ${esc(c.title)}</a><p>${esc(clip(c.account, 140))}</p></li>`))}</div>`;
  return { title: "The Vault: evidence of the weird and unexplainable · " + SITE, desc, canonical: ORIGIN + "/vault", content };
}

async function pageFor(url) {
  const seg = url.pathname.split("/").filter(Boolean).map(x => { try { return decodeURIComponent(x) } catch (e) { return x } });
  const [a, b] = seg;
  if (a === "post") return UUID.test(b || "") ? postPage(b) : notFound("Post");
  if (a === "vault" && !b) return vaultPage();
  if (a === "vault" && /^case-\d{1,9}$/.test(b)) return casePage(parseInt(b.slice(5), 10));
  if (a === "u" && b) return profilePage(b);
  if (a === "topics" && b) return topicPage(b);
  if (a === "question" && /^\d{4}-\d{2}-\d{2}$/.test(b)) return questionPage(b);
  return null;
}

// ---------- writing the details into the page ----------

function applyMeta(html, page) {
  const set = (re, tag) => { html = re.test(html) ? html.replace(re, () => tag) : html.replace("</head>", () => tag + "\n</head>") };
  set(/<title>[\s\S]*?<\/title>/, `<title>${esc(page.title)}</title>`);
  set(/<meta name="description" content="[^"]*">/, `<meta name="description" content="${esc(page.desc)}">`);
  set(/<meta property="og:title" content="[^"]*">/, `<meta property="og:title" content="${esc(page.title)}">`);
  set(/<meta property="og:description" content="[^"]*">/, `<meta property="og:description" content="${esc(page.desc)}">`);
  set(/<meta property="og:type" content="[^"]*">/, `<meta property="og:type" content="${page.type || "website"}">`);
  if (page.canonical) {
    set(/<link rel="canonical" href="[^"]*">/, `<link rel="canonical" href="${esc(page.canonical)}">`);
    set(/<meta property="og:url" content="[^"]*">/, `<meta property="og:url" content="${esc(page.canonical)}">`);
  } else {
    html = html.replace(/<link rel="canonical" href="[^"]*">\n?/, "").replace(/<meta property="og:url" content="[^"]*">\n?/, "");
  }
  if (page.image) {
    set(/<meta property="og:image" content="[^"]*">/, `<meta property="og:image" content="${esc(page.image)}">`);
    html = html.replace(/<meta property="og:image:(width|height)" content="[^"]*">\n?/g, "");
  }
  if (page.robots) set(/<meta name="robots" content="[^"]*">/, `<meta name="robots" content="${page.robots}">`);
  if (page.jsonld) html = html.replace("</head>", () => `<script type="application/ld+json">${JSON.stringify(page.jsonld).replace(/</g, "\\u003c")}</script>\n</head>`);
  if (page.content) {
    html = html.replace('<section id="pageView" hidden></section>', () => `<section id="pageView" data-prerendered>${page.content}</section>`);
    html = html.replace('<section class="hero" id="hero">', () => '<section class="hero" id="hero" hidden>');
    html = html.replace('<div id="feedView">', () => '<div id="feedView" hidden>');
  }
  return html;
}

export default async (request, context) => {
  const res = await context.next();
  if (res.status !== 200 || !(res.headers.get("content-type") || "").includes("text/html")) return res;
  const page = await pageFor(new URL(request.url));
  if (!page) return res; // unknown page or Supabase unreachable: serve the site as usual
  const html = applyMeta(await res.text(), page);
  const headers = new Headers(res.headers);
  headers.delete("content-length");
  headers.delete("etag");
  headers.set("cache-control", "public, max-age=0, must-revalidate");
  headers.set("netlify-cdn-cache-control", "public, s-maxage=300, stale-while-revalidate=3600");
  return new Response(html, { status: page.status || 200, headers });
};

export const config = {
  path: ["/post/*", "/vault", "/vault/*", "/u/*", "/topics/*", "/question/*"],
  excludedPath: ["/vault/new"],
  cache: "manual",
  onError: "bypass",
};
