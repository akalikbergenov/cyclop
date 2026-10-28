// Сайт cyclopnotch.app. Статика без единого скрипта на клиенте: страницы
// должны помещаться в первые килобайты — в России сайты за Cloudflare
// замедляют так, что доходит лишь начало ответа.
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";


export default defineConfig({
  site: "https://cyclopnotch.app",
  trailingSlash: "always",
  build: { inlineStylesheets: "always", format: "directory" },

  i18n: {
    defaultLocale: "en",
    locales: ["en", "ru"],
    routing: { prefixDefaultLocale: false },
  },

  integrations: [
    sitemap({
      i18n: { defaultLocale: "en", locales: { en: "en", ru: "ru" } },
    }),
  ]
});