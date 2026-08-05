# Fotos de referencia para que Jarvis reconozca a la familia

Pon aquí una foto de cada persona, con su nombre como nombre de archivo:

```
server/family/Laura.jpg
server/family/Mario.jpg
```

Formatos válidos: `.jpg`, `.jpeg`, `.png`, `.webp`. El nombre del archivo
(sin la extensión) es el nombre que Jarvis usará — usa mayúscula inicial y,
si es un nombre compuesto, guiones o guiones bajos (`Juan_Carlos.jpg` →
"Juan Carlos").

No hace falta reiniciar el servidor: se leen en cada foto que llega. Cuando
alguien le enseñe la cámara a Jarvis (diciendo algo como "mira esto" o
enviándole una foto), las compara contra estas y, si tiene bastante
confianza, te habla por tu nombre y usa lo que sepa de ti. Si no reconoce a
nadie, simplemente no lo menciona — no inventa quién eres.

Usa fotos con la cara bien visible y buena luz; con fotos borrosas o muy
lejanas el reconocimiento es poco fiable.

Estas fotos son solo tuyas: **no se suben al repositorio de git** (están
excluidas en `.gitignore`), solo viven en este Mac y se envían a Claude como
parte de la conversación, igual que cualquier otra foto que le mandes a
Jarvis.
