# Логотип Mac O Blox

`logo_1024.png` собран из двух скачанных оригиналов, ничего не рисовалось заново:

- Значок Roblox Player с Wikimedia Commons (в репозиторий не входит).
  От него остался только наклон: квадрат, повёрнутый на 15°, это четыре
  точки в `square.svg`. Цвет свой (градиент #8b5cf6 → #2563eb), родной
  квадратной дырки нет.
- `source/Tux.svg`: Tux, автор Larry Ewing (lewing@isc.tamu.edu),
  нарисован в The GIMP; Wikimedia Commons. Использован силуэт Тукса как
  вырез в центре квадрата.

`square.svg`: перекрашенный квадрат. Сборка: см. историю в этом каталоге,
вырез делается `magick ... -compose DstOut`.

Ни рисунка, ни цвета Roblox в иконке нет, наклонённый квадрат только
отсылает к нему. Автора Тукса нужно упоминать: Larry Ewing и The GIMP.

## Остальные файлы

- `wordmark-light.png`, `wordmark-dark.png`: длинный логотип для README
  (светлая и тёмная тема GitHub). Собираются `./make_wordmark.py`.
- `source/Comfortaa[wght].ttf`: шрифт Comfortaa, SIL OFL (`source/Comfortaa-OFL.txt`).
- `discord_icon.png`: иконка сервера Discord, логотип с отступом на тёмном
  фоне, чтобы круглая обрезка не срезала углы.
- Иконки Discord и GitHub в лаунчере (`launcher/icons`) взяты из Simple Icons (CC0).
