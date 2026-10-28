import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

const blog = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    date: z.coerce.date(),
    lang: z.enum(["en", "ru"]),
    // Ключ пары переводов: у английской и русской версии он один, по нему
    // страницы ссылаются друг на друга через hreflang.
    pair: z.string().optional(),
  }),
});

export const collections = { blog };
