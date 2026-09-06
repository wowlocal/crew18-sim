# Podlodka Dive — визуальные ресурсы

Вся игровая сцена — векторный рисунок в `PodlodkaDive/GameCanvas.swift`:
золотой батискаф, стекло иллюминаторов, винт, луч фонаря, пузыри, рифы,
кораллы, рыбки, течения, сонар, база, затонувший корабль, мины и предметы.
Видимая область имеет ширину 390 игровых единиц; камера перемещается
по сектору 1560×2600. Коллизии рифов используют те же вершины, что и рисунок.
Системная настройка Reduce Motion отключает покачивание, движение частиц
и декоративный сонар; прокрутка игрового мира сохраняется.

Иконка: `PodlodkaDive/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
Создана встроенным инструментом imagegen; CLI и внешние стоковые ресурсы
не использовались. Результат приведён к 1024×1024 через `sips` для каталога Xcode.
Иконка непрозрачная, углы скругляет iOS.

Промпт генерации:

> Use case: stylized-concept. Asset type: final iOS app icon for a small underwater arcade game, a square 1024x1024 image. Create one beautiful polished minimal game icon, full bleed square, no rounded-corner mask. A charming compact golden yellow bathyscaphe submarine in side view facing right, occupying 70% of the image width, centered. Capsule-shaped golden hull, exactly two round turquoise glass portholes with brass rims and tiny glints, short curved periscope on top, small copper tail fin and silver propeller on the left. A soft cone of headlight extends right into dark deep teal ocean. Refined softly shaded illustrated style, like a beautiful handcrafted indie iPhone game, very clean legible silhouette, subtle material shading, no heavy outlines, no hyperrealism. Background dark navy teal #061e2b with faint concentric sonar circles, a few tiny bubbles behind propeller, gentle teal light from upper left. Palette warm amber #ffc454, muted mint #61e3cb, deep teal. Quiet adventurous mood. No text, no letters, no numbers, no badge, no border, no frame, no watermark. Opaque background, square composition.
