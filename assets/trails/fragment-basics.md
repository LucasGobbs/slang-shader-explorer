# Fragment shaders do zero

Três cenas, três ideias centrais: coordenadas normalizadas, tempo e interação. Ao fim desta trilha você escreve um efeito animado que responde ao mouse.

## 1. Todo pixel executa o seu código

Um fragment shader é uma função chamada uma vez por pixel. Ela recebe a coordenada do pixel e devolve uma cor. Com milhões de chamadas independentes por frame, imagens inteiras emergem de poucas linhas.

O primeiro passo é normalizar a coordenada: dividir o pixel pela resolução dá um uv entre 0 e 1, independente do tamanho da janela.

```
float2 uv = frag_coord / Uniforms.iResolution.xy;
```

[Abrir a cena 01_hello_pixel](scene:01_hello_pixel) — troque uv.x por uv.y no gradiente e salve (Cmd+S): a cena recompila ao vivo.

## 2. Tempo dá movimento

O bloco SceneUniforms entrega iTime, os segundos desde o início da cena. Passar iTime por sin() produz movimento periódico sem nenhum estado: cada frame é uma função pura do relógio.

```
float pulse = 0.5 + 0.5 * sin(Uniforms.iTime);
```

[Abrir a cena 02_time](scene:02_time) — dê fases diferentes aos canais RGB (+0.0, +2.1, +4.2) e veja o branco se separar em cores.

## 3. O mouse torna o shader interativo

iMousePos (em pixels) e iMouseClick (0 ou 1) chegam pelo mesmo bloco de uniforms. Distância do pixel ao cursor vira um holofote; smoothstep suaviza a borda.

```
float d = distance(frag_coord, Uniforms.iMousePos);
float light = smoothstep(radius, 0.0, d);
```

[Abrir a cena 03_mouse](scene:03_mouse) — troque smoothstep por step e compare a borda. Depois inverta a direção (uv - dir) para o holofote repelir.

## Próximo passo

Combine os três: um gradiente (cena 01) que pulsa com o tempo (cena 02) e se concentra onde o mouse aponta (cena 03). Crie uma cena nova pelo menu + novo na barra de título e monte o seu.
