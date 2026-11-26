# Modo vidente — como funciona (guia de aprendizado)

Este documento explica **como o Balatro sorteia as coisas** e **como o modo vidente do Engine Sim BR lê o futuro**,
com os trechos de código onde cada parte acontece. Serve para aprender a programar mods de Balatro.

> Liga e desliga com **F4** (ou em Mods → Engine Sim BR → Config). Desligado por padrão: ele tira o desafio da run.

## 1. O Balatro não tem sorte "de verdade"

Tudo que parece aleatório sai da **seed** da run. O jogo usa duas funções (do código do próprio Balatro, em Lua):

- `pseudoseed(chave)` — cada tipo de sorteio tem um **fluxo com nome**: `'lucky_mult'` (cartas da Sorte, +20 Mult),
  `'misprint'`, `'glass'` (vidro quebrar), `'wheel_of_fortune'`, `'boss'`, `'nr1'` (embaralhar o baralho na ante 1)
  e assim por diante. O estado de cada fluxo é **um número** guardado em `G.GAME.pseudorandom[chave]`.
  Cada chamada avança esse número por uma conta fixa e devolve uma semente.
- `pseudorandom(chave, min, max)` — chama `pseudoseed(chave)`, alimenta o gerador do Lua (`math.randomseed`) com a
  semente e devolve `math.random()` (ou um inteiro entre `min` e `max`).

Duas consequências importantes:

1. **Os fluxos são independentes.** O próximo resultado de `'lucky_mult'` só muda quando uma carta da Sorte testa o
   Mult — não importa quantas outras coisas aleatórias aconteçam no meio.
2. **Dá para espiar sem estragar nada.** Se você guarda o número do fluxo, chama `pseudorandom` algumas vezes e
   depois põe o número de volta, o jogo vai produzir **exatamente os mesmos valores, na mesma ordem**, quando for a
   vez dele.

## 2. Nível 1 — a ordem exata do baralho

No começo de cada rodada o jogo embaralha o baralho **uma vez** (`G.deck:shuffle('nr'..ante)`) e depois **sempre
compra a última carta** de `G.deck.cards` (a função `CardArea:remove_card` pega `cards[#cards]` numa área do tipo
baralho). Ou seja: a lista `G.deck.cards`, na ordem em que está, já **é o futuro** — a última carta é a próxima que
vai para a sua mão.

O motor original lia essa lista (`gs.remaining` em `core/state_extraction.lua`), mas a tratava como um monte
desconhecido e **embaralhava ao acaso milhares de vezes** para estimar médias (Monte-Carlo). No modo vidente:

- `engine/seer.lua` marca a lista como **"ordem conhecida"** (`Seer.mark`);
- os lugares do motor que sorteavam cartas — avaliação de descarte (`engine/discard_value.lua`), simulação de
  sobrevivência (`engine/simulation.lua`) e busca (`engine/search.lua`) — chamam `Seer.order(...)` em vez de
  embaralhar: uma lista conhecida volta **na ordem real**;
- com a ordem conhecida, **uma** simulação já é exata (`Seer.samples` devolve 1), então fica até mais rápido.

### A autoconferência

Como não dá para ter certeza absoluta de que toda versão do jogo/Steamodded compra do fim da lista, o mod **confere
sozinho** (`BES.seer_validate` em `main.lua`): antes de cada compra ele anota quais cartas deveriam chegar; depois
da compra, compara com as que realmente chegaram. Acertou → "ordem confirmada N vezes" no painel. Errou duas vezes
(mais erros que acertos) → o mod **para de usar a ordem** e avisa no painel e no log do Lovely.

## 3. Nível 2 — a sorte de cada rolagem

`core/state_extraction.lua` → `Extract.peek_rolls` faz o truque da seção 1 para os fluxos de sorte:

```lua
local saved = G.GAME.pseudorandom[key]            -- guarda o estado do fluxo
for i = 1, n do vals[i] = pseudorandom(key) end   -- lê os próximos n valores (função do próprio jogo)
G.GAME.pseudorandom[key] = saved                  -- devolve: o jogo vai tirar os mesmos valores depois
```

Com isso, `engine/hand_eval.lua` deixa de usar médias (uma carta da Sorte valia "+4 Mult em média") e usa o
**resultado real**: a 1ª carta da Sorte pontuada usa o 1º valor de `'lucky_mult'` (acerta se for menor que
`probabilidade/5`), a 2ª usa o 2º, e assim por diante. Vale para: cartas da Sorte (Mult e $20), Misprint,
Bloodstone e Business Card. O painel ainda mostra o que vai acontecer com Vidro, Wheel of Fortune, Gros Michel,
Cavendish, Reserved Parking, 8 Ball e Space Joker.

O **próximo chefe** (`Extract.peek_next_boss`) usa a mesma ideia com a função `get_new_boss()` do jogo: sobe a ante
em 1, chama a função, e restaura tudo que ela mexe (fluxo `'boss'`, contagem de chefes usados, ante). É
experimental: um reroll de chefe (Boss Tag, Director's Cut) muda o resultado.

## 4. O que (ainda) não dá para prever assim

- **A próxima loja depois de um reroll** e **o conteúdo de um pacote antes de comprar**: dependem de vários fluxos
  ao mesmo tempo, das cartas que você já tem (o jogo não repete coringas) e do Steamodded, que reescreve a criação de
  cartas. É o próximo passo possível, com o mesmo método de salvar/restaurar estado.
- **Rodadas futuras**: o embaralhamento da próxima rodada só acontece quando ela começa (e depende de quais cartas
  estão no baralho), então o mod só vê a ordem da rodada atual.

## 5. Onde mexer para aprender

| Arquivo | O que tem |
|---|---|
| `core/state_extraction.lua` | o **único** arquivo que lê o jogo (`G`): `peek_rolls`, `peek_next_boss` |
| `engine/seer.lua` | ordem conhecida, rolagens por fluxo, linhas do painel (puro, testável sem o jogo) |
| `engine/hand_eval.lua` | a pontuação; procure `seer_effect` |
| `main.lua` | liga/desliga (F4), autoconferência, painel "Futuro" |
| `tests/test_seer.lua` | testes que rodam sem o jogo (`lua5.4 tests/runner.lua`) |

Dica para experimentar: com um mod de console (como o DebugPlus) ou um `print` temporário no código,
`G.GAME.pseudorandom` mostra todos os fluxos que a run já usou, e `G.deck.cards[#G.deck.cards].base` é a próxima
carta que você vai comprar.
