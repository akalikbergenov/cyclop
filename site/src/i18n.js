// Тексты лендинга на двух языках. Переводы не дословные: у каждого языка свои
// запросы в поиске и свои привычки — русскому читателю ближе Яндекс Музыка и
// Телемост, английскому — Spotify и Zoom.

export const t = {
  en: {
    htmlLang: "en",
    ogLocale: "en_US",
    title: "Cyclop — free notch app for MacBook",
    description:
      "Cyclop turns the MacBook notch into a panel: music from any app or browser tab, a file shelf, clipboard history, snippets and your next meeting. Free, open source, nothing asked at launch.",
    nav: { blog: "Blog", privacy: "Privacy", github: "GitHub", other: "Русский", otherHref: "/ru/" },
    h1: "The MacBook notch as a working tool",
    lede:
      "Invisible at rest. Hover the notch and it unfolds into a panel with your music, a shelf for files, clipboard history and your next meeting. Free and open source.",
    download: "Download for Mac",
    meta: (r) => `Version ${r.version} · ${r.sizeMB} MB · macOS 15 or newer, Apple silicon`,
    source: "Source on GitHub",
    shotAlt: "The Cyclop panel unfolded from the MacBook notch, playing a track from a browser tab",
    shotCaption:
      "The track is playing in a browser tab. Cyclop reads it from macOS itself — no extension, no permission.",
    promiseTitle: "What it asks of your Mac",
    promise:
      "Nothing at launch. Two permissions, each asked only on a button press, after an explanation: Calendar and Accessibility. The only network traffic is currency rates and, on the fallback path, Spotify artwork. 0 % CPU at rest.",
    facts: [
      ["0 %", "CPU at rest"],
      ["≈40 MB", "memory"],
      ["0", "asked at launch"],
      ["MIT", "free licence"],
    ],
    tabsTitle: "Ten tabs, each one can be switched off",
    tabsLede:
      "Switching a tab off in Settings removes its icon and stops its background work. Keep only what you use.",
    tabs: [
      ["Music", "Artwork, track, a scrubber that seeks, play and skip. The source is anything macOS sees: Apple Music, Spotify, a YouTube tab."],
      ["Shelf", "Drag files into the notch, drag them out where they are needed. A screenshot copied on your iPhone lands here too."],
      ["Clipboard", "The last 40 copies, one click to put any back. Password managers never end up in the history."],
      ["Snippets", "Addresses, phone numbers, emails you are tired of typing. One click copies; the list is a plain file you can edit."],
      ["Calendar", "Your next meeting, how long until it starts and a button that joins the call: Zoom, Meet, Teams and five more."],
      ["Translate", "Offline translation between English and Russian with macOS's own engine. No service, no account."],
      ["Currency", "Type an amount on either side; rates are refreshed hourly while the tab is on."],
      ["Teleprompter", "A script that scrolls right under the camera, so on a recording your eyes stay on the lens."],
      ["Notes", "Scratch space for a number from a call or half a thought. Empty notes clean themselves up."],
      ["Utilities", "Lock the keyboard and trackpad to wipe them. Hold Esc for 2 seconds to unlock, or wait a minute."],
    ],
    whyTitle: "Why people pick Cyclop",
    why: [
      ["Music from anywhere", "Anything that shows up in Control Center's Now Playing shows up in the notch — a player, a browser tab, a video. Nothing to install in the browser."],
      ["Nothing at launch", "No permission dialogs when you open it. Calendar and Accessibility are asked only when you press the button that needs them."],
      ["Free, no account", "No subscription, no licence server that can go down, no sign-in. MIT licence; the whole source is on GitHub."],
      ["Quiet", "0 % CPU while you are not looking at it. A tab you switch off stops its background work completely."],
      ["Safe to share your screen", "One click hides the contents of the clipboard, snippets, calendar and notes during a call or a stream."],
      ["Built in the open", "Signed and notarised by Apple, reviewed pull requests, every outgoing request listed in SECURITY.md."],
    ],
    installTitle: "Install in a minute",
    install: [
      "Download the .dmg above.",
      "Drag Cyclop into Applications and open it — it is signed and notarised, so it opens on the first try.",
      "Move the pointer to the notch. On a Mac or display without one, a thin strip at the top centre does the same.",
    ],
    faqTitle: "Questions",
    faq: [
      ["Is Cyclop free?", "Yes, completely: no trial, no subscription, no paid tier. It is open source under the MIT licence."],
      ["Does it work on a Mac without a notch?", "Yes. On a Mac or external display without a cutout, Cyclop marks a notch of its own: a thin strip at the top centre of the screen opens the panel the same way."],
      ["What permissions does it need?", "Nothing at launch. Calendar is asked for in the Calendar tab and Accessibility for the keyboard lock, each only when you press the button. Switch a tab off and its permission is never asked."],
      ["Does it send anything over the network?", "No telemetry and no analytics in the app. Currency rates are downloaded hourly while that tab is on, and Spotify artwork only on the fallback player path. Everything else stays on your Mac."],
      ["Which Macs are supported?", "macOS 15 or newer on Apple silicon."],
      ["How do I update?", "Download the new version here and replace the app in Applications. Your settings, snippets and notes stay where they are."],
    ],
    ctaTitle: "Try it — it's free",
    footer: "Cyclop is free and open source, MIT licence.",
    blogTitle: "Blog",
    blogLede: "How to get more out of the MacBook notch, and what is new in Cyclop.",
    readMore: "Read",
    privacyTitle: "Privacy",
    dateLocale: "en-GB",
  },
  ru: {
    htmlLang: "ru",
    ogLocale: "ru_RU",
    title: "Cyclop — бесплатное приложение для чёлки MacBook",
    description:
      "Cyclop превращает чёлку MacBook в панель: музыка из любого приложения и вкладки браузера, полка для файлов, история буфера, заготовки и ближайшая встреча. Бесплатно, открытый код, при запуске ничего не спрашивает.",
    nav: { blog: "Блог", privacy: "Приватность", github: "GitHub", other: "English", otherHref: "/" },
    h1: "Чёлка MacBook как рабочий инструмент",
    lede:
      "В покое её не видно. Наведите курсор на чёлку — и она развернётся в панель с музыкой, полкой для файлов, историей буфера и ближайшей встречей. Бесплатно и с открытым кодом.",
    download: "Скачать для Mac",
    meta: (r) => `Версия ${r.version} · ${String(r.sizeMB).replace(".", ",")} МБ · macOS 15 и новее, Apple silicon`,
    source: "Исходники на GitHub",
    shotAlt: "Панель Cyclop, развёрнутая из чёлки MacBook: играет трек из вкладки браузера",
    shotCaption:
      "Трек играет во вкладке браузера. Cyclop берёт его у самой macOS — без расширений и разрешений.",
    promiseTitle: "Что приложение просит у вашего Mac",
    promise:
      "Ничего при запуске. Разрешений два, оба по кнопке и после объяснения: Календарь и Универсальный доступ. По сети ходят только курсы валют и, на запасном пути, обложка Spotify. 0 % CPU в покое.",
    facts: [
      ["0 %", "CPU в покое"],
      ["≈40 МБ", "памяти"],
      ["0", "вопросов при запуске"],
      ["MIT", "свободная лицензия"],
    ],
    tabsTitle: "Десять вкладок, любую можно выключить",
    tabsLede:
      "Выключенная в настройках вкладка убирает иконку и останавливает свою фоновую работу. Оставьте только то, чем пользуетесь.",
    tabs: [
      ["Музыка", "Обложка, трек, перемотка, пауза и переключение. Источник — всё, что видит macOS: Яндекс Музыка, Apple Music, Spotify, вкладка YouTube."],
      ["Полка", "Перетащите файлы в чёлку и вытащите там, где они нужны. Сюда же приходит снимок экрана, скопированный на айфоне."],
      ["Буфер", "Последние 40 копирований, любое возвращается одним кликом. Пароли из менеджеров в историю не попадают."],
      ["Заготовки", "Почта, телефон, адрес — то, что надоело набирать. Клик копирует, а сам список — обычный файл, его можно править."],
      ["Календарь", "Ближайшая встреча, сколько до неё и кнопка подключения: Телемост, Zoom, Meet, Teams и другие."],
      ["Перевод", "Офлайн-перевод между русским и английским средствами самой macOS. Без сервисов и аккаунтов."],
      ["Валюта", "Сумму можно вводить с любой стороны; курсы обновляются раз в час, пока вкладка включена."],
      ["Телесуфлёр", "Сценарий ползёт прямо под камерой — на записи взгляд остаётся в объективе."],
      ["Заметки", "Черновик для номера из звонка или половины мысли. Пустые заметки убираются сами."],
      ["Утилиты", "Блокировка клавиатуры и трекпада, чтобы их протереть. Снимается удержанием Esc 2 секунды или сама через минуту."],
    ],
    whyTitle: "Почему выбирают Cyclop",
    why: [
      ["Музыка откуда угодно", "Всё, что видно в «Исполняется» Пункта управления, видно и в чёлке — плеер, вкладка браузера, видео. Ничего не нужно ставить в браузер."],
      ["Ничего при запуске", "Никаких окон с разрешениями при открытии. Календарь и Универсальный доступ спрашиваются, только когда нажимаете кнопку, которой они нужны."],
      ["Бесплатно и без аккаунта", "Без подписки, без сервера лицензий, который может упасть, без входа. Лицензия MIT, весь код на GitHub."],
      ["Тихое", "0 % процессора, пока вы на него не смотрите. Выключенная вкладка полностью останавливает свою фоновую работу."],
      ["Можно показывать экран", "Один клик — и содержимое буфера, заготовок, календаря и заметок скрыто на время созвона или стрима."],
      ["Сделано открыто", "Подписано и нотаризовано Apple, правки проходят ревью, каждый сетевой запрос перечислен в SECURITY.md."],
    ],
    installTitle: "Установка за минуту",
    install: [
      "Скачайте .dmg по кнопке выше.",
      "Перетащите Cyclop в «Программы» и откройте — приложение подписано и нотаризовано, открывается с первого раза.",
      "Подведите курсор к чёлке. На маке или мониторе без выреза то же делает тонкая полоска вверху по центру.",
    ],
    faqTitle: "Вопросы",
    faq: [
      ["Cyclop бесплатный?", "Да, полностью: без пробного периода, подписки и платных функций. Открытый код под лицензией MIT."],
      ["Работает ли на маке без чёлки?", "Да. На маке или внешнем мониторе без выреза Cyclop рисует свою чёлку: тонкая полоска вверху по центру экрана открывает панель так же."],
      ["Какие разрешения нужны?", "При запуске — никаких. Календарь спрашивается на вкладке «Календарь», Универсальный доступ — для блокировки клавиатуры, и оба только по нажатию кнопки. Выключите вкладку — и её разрешение не спросится никогда."],
      ["Отправляет ли что-нибудь в сеть?", "В приложении нет ни телеметрии, ни аналитики. Курсы валют скачиваются раз в час, пока включена вкладка «Валюта», а обложка Spotify — только на запасном пути. Всё остальное остаётся на вашем маке."],
      ["Какие маки поддерживаются?", "macOS 15 и новее на Apple silicon."],
      ["Как обновить?", "Скачайте новую версию здесь и замените приложение в «Программах». Настройки, заготовки и заметки останутся на месте."],
    ],
    ctaTitle: "Попробуйте — это бесплатно",
    footer: "Cyclop бесплатный и с открытым кодом, лицензия MIT.",
    blogTitle: "Блог",
    blogLede: "Как выжать больше из чёлки MacBook и что нового в Cyclop.",
    readMore: "Читать",
    privacyTitle: "Приватность",
    dateLocale: "ru-RU",
  },
};

export const prefix = (lang) => (lang === "ru" ? "/ru" : "");
