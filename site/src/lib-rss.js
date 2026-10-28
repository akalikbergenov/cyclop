import rss from "@astrojs/rss";
import { getCollection } from "astro:content";
import { t, prefix } from "./i18n.js";

export async function feed(context, lang) {
  const s = t[lang];
  const posts = (await getCollection("blog", (e) => e.data.lang === lang))
    .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
  return rss({
    title: `Cyclop — ${s.blogTitle}`,
    description: s.blogLede,
    site: context.site,
    items: posts.map((post) => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.date,
      link: `${prefix(lang)}/blog/${post.id.split("/").pop()}/`,
    })),
    customData: `<language>${lang}</language>`,
  });
}
