"""Interface strings. English is the source language; set_language("ru")
switches to Russian."""

LANGUAGES = {"en": "English", "ru": "Русский"}

_language = "en"

RU = {
    # Pages
    "Play": "Играть",
    "Fast flags": "Фастфлаги",
    "Settings": "Настройки",
    "Info": "Инфо",
    # Play page
    "Roblox {version}": "Roblox {version}",
    "Roblox not found": "Roblox не найден",
    "Darling running": "Darling запущен",
    "Darling starts with the game": "Darling запустится при старте",
    "Roblox is running": "Roblox запущен",
    "Starting…": "Запускаю…",
    "Stop Roblox": "Остановить Roblox",
    "Install Roblox": "Установить Roblox",
    "Open last log": "Открыть последний лог",
    "Could not start: {error}": "Не удалось запустить: {error}",
    "Roblox exited with code {status}": "Roblox завершился с кодом {status}",
    # Fast flags
    "FPS limit": "Лимит FPS",
    "Graphics quality": "Качество графики",
    "No shadows": "Без теней",
    "No grass": "Без травы",
    "Popular": "Популярные",
    "Roblox only applies flags from its allowlist, some flags may have no effect.":
        "Roblox применяет только флаги из своего списка разрешённых, часть флагов может не действовать.",
    "Custom flags": "Свои флаги",
    "Add flag": "Добавить флаг",
    "Import JSON": "Импорт JSON",
    "File": "Файл",
    "New flag": "Новый флаг",
    "Name": "Название",
    "Value": "Значение",
    "Remove": "Удалить",
    "Import fast flags": "Импорт фастфлагов",
    'Paste JSON like {"Flag": value}. Flags are added to the current ones.':
        'Вставь JSON вида {"Флаг": значение}. Флаги добавятся к текущим.',
    "Cancel": "Отмена",
    "Import": "Импортировать",
    "This is not a JSON object with flags": "Это не JSON-объект с флагами",
    "Imported flags: {count}": "Импортировано флагов: {count}",
    "Could not save flags: {error}": "Не удалось сохранить флаги: {error}",
    # Settings: game
    "Game": "Игра",
    "Camera sensitivity": "Чувствительность камеры",
    "Mouse movement multiplier while rotating the camera":
        "Множитель движения мыши при вращении камеры",
    "Show the launcher after Roblox exits": "Показывать лаунчер после выхода из Roblox",
    "Hide the macOS menu bar": "Скрывать полоску меню macOS",
    "The Roblox, Edit, Window… strip at the top of the game window":
        "Полоска Roblox, Edit, Window… сверху окна игры",
    # Settings: DNS
    "DNS for Roblox": "DNS для Roblox",
    "Only Roblox uses this server, the rest of the system keeps its own DNS. "
    "Helps when some Roblox images or servers do not load.":
        "Этот сервер использует только Roblox, остальная система остаётся на своём DNS. "
        "Помогает, если не грузятся картинки или сервера Roblox.",
    "DNS server": "DNS-сервер",
    "System (Darling default)": "Системный (как в Darling)",
    "Quad9 (9.9.9.9, encrypted)": "Quad9 (9.9.9.9, шифрованный)",
    "Cloudflare (1.1.1.1, encrypted)": "Cloudflare (1.1.1.1, шифрованный)",
    "Google (8.8.8.8, encrypted)": "Google (8.8.8.8, шифрованный)",
    "Custom": "Свой",
    "Custom server": "Свой сервер",
    "IP address, optionally with :port. Plain DNS, not encrypted.":
        "IP-адрес, можно с :портом. Обычный DNS, без шифрования.",
    # Settings: language
    "Interface": "Интерфейс",
    "Language": "Язык",
    # Settings: Roblox
    "Installed version": "Установленная версия",
    "not found": "не найдена",
    "Check for updates": "Проверить обновления",
    "Checking…": "Проверяю…",
    "Could not check: {error}": "Не удалось проверить: {error}",
    "The latest version is installed": "Установлена последняя версия",
    "Update to {version}": "Обновить до {version}",
    "Close Roblox first": "Сначала закрой Roblox",
    "Update failed: {error}": "Обновление не удалось: {error}",
    "Roblox updated, the old version is in backups/": "Roblox обновлён, старая версия в backups/",
    "Downloading {done} of {total} MB": "Загрузка {done} из {total} МБ",
    "Unpacking": "Распаковка",
    "Done": "Готово",
    "The download is not a zip archive": "Скачанный файл не является zip-архивом",
    "The archive has no RobloxPlayer.app": "В архиве нет RobloxPlayer.app",
    # Settings: account
    "Account": "Аккаунт",
    "Sign out": "Выйти из аккаунта",
    "Sign out?": "Выйти из аккаунта?",
    "The saved Roblox session will be deleted, you will need to sign in again next time.":
        "Сохранённая сессия Roblox будет удалена, при следующем запуске нужно будет войти заново.",
    "Sign out of Roblox": "Выйти",
    "Session deleted": "Сессия удалена",
    # Settings: diagnostics
    "Diagnostics": "Диагностика",
    "Detailed logs for debugging. They slow the game down, enable only when needed.":
        "Подробные логи для отладки. Замедляют игру, включай только когда нужно.",
    "Backtrace on crashes": "Бэктрейс при крашах",
    "Network tracing (UDP)": "Трассировка сети (UDP)",
    "Mouse lock tracing": "Трассировка захвата мыши",
    "Mouse event tracing": "Трассировка событий мыши",
    "OpenGL tracing": "Трассировка OpenGL",
    "Open logs folder": "Открыть папку с логами",
    "Rebuild shim": "Пересобрать шим",
    "Building the shim…": "Собираю шим…",
    "Shim built": "Шим собран",
    "Build failed, details in the terminal": "Сборка не удалась, подробности в терминале",
    "Could not build the shim:\n{output}": "Не удалось собрать шим:\n{output}",
    "Restart Darling": "Перезапустить Darling",
    "Darling stopped, it starts with the next game": "Darling остановлен, запустится при следующей игре",
    # Info
    "Mac O’ Blox runs the real Roblox client for macOS on Linux through Darling. "
    "It is not made by Roblox and is not affiliated with it.":
        "Mac O’ Blox запускает настоящий клиент Roblox для macOS на Linux через Darling. "
        "Его делает не Roblox, и с Roblox он никак не связан.",
    "Community": "Сообщество",
    "Author": "Автор",
    "{user} on Roblox": "{user} в Roblox",
    "Made with Claude Opus 5.5": "Сделано с Claude Opus 5.5",
    "Anthropic's AI wrote the code together with the author": "ИИ от Anthropic писал код вместе с автором",
    "Support the project": "Поддержать проект",
    "Mac O’ Blox is free. If it helped you, you can thank the author.":
        "Mac O’ Blox бесплатный. Если он тебе пригодился, можно поблагодарить автора.",
    "Boosty": "Boosty",
    "Cards from any country": "Карты любых стран",
    "YooMoney": "ЮMoney",
    "For Russia": "Для России",
}


def set_language(code):
    global _language
    _language = code if code in LANGUAGES else "en"


def language():
    return _language


def _(text, **values):
    if _language == "ru":
        text = RU.get(text, text)
    return text.format(**values) if values else text
