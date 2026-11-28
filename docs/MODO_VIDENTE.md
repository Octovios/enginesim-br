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
baralho). Ou seja: durante a rodada, a lista `G.deck.cards`, na ordem em que está, já **é o futuro** — a última carta
é a próxima que vai para a sua mão.

O motor original lia essa lista (`gs.remaining` em `core/state_extraction.lua`), mas a tratava como um monte
desconhecido e **embaralhava ao acaso milhares de vezes** para estimar médias (Monte-Carlo). No modo vidente:

- `engine/seer.lua` marca a lista como **"ordem conhecida"** (`Seer.mark`) — só **dentro da rodada**;
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

## 4. Nível 3 — o que vem nos pacotes, na loja e nas tags

Tudo isso está em **`core/seer_peek.lua`**. A ideia é a mesma da seção 3, só que agora o mod precisa refazer a
**receita inteira** com que o jogo cria uma carta, porque uma carta usa **vários fluxos** ao mesmo tempo.

### 4.1 A receita de uma carta

O jogo cria cartas com `create_card` (em `functions/common_events.lua`; o Steamodded remenda essa função com os
arquivos `lovely/center.toml`, `pool.toml`, `rarity.toml`, `sticker.toml` e `edition.toml`). Para um pacote, cada
carta passa por estes passos — cada um com **o seu fluxo**:

| Passo | Fluxo (ante 1, por exemplo) | O que decide |
|---|---|---|
| A Alma / Buraco Negro | `soul_Tarot1`, `soul_Spectral1`, `soul_Planet1` | se o valor passar de 0,997 a carta vira A Alma (ou o Buraco Negro) |
| raridade (só coringas) | `rarity1buf` | Comum (até 0,7), Incomum (até 0,95) ou Rara |
| qual carta | `Tarotar11`, `Planetpl11`, `Joker1buf1`, `Spectralspe1`... | sorteia na lista de cartas possíveis |
| re-sorteio | `Joker1buf1_resample2`, `_resample3`... | quando caiu numa carta "indisponível" |
| edição (coringas) | `edibuf1` | Laminado, Holográfico, Policromático, Negativo |
| adesivos (fichas altas) | `packetper1`, `packssjr1` | Eterno, Perecível, Alugado |
| face (cartas comuns) | `frontsta1` | o valor e o naipe |

A parte do meio do nome é **de onde a carta vem**: `ar1` = pacote Arcana, `pl1` = Celestial, `buf` = Bufão,
`spe` = Espectral, `sta` = Padrão, `sho` = loja. Por isso um pacote Arcana e um tarô avulso da loja **não disputam**
o mesmo fluxo.

E tem a regra que deixa tudo interessante: **o jogo nunca oferece uma carta que já está "fora"** — com você, na
prateleira da loja, ou mais cedo **no mesmo pacote**. Essa lista é `G.GAME.used_jokers` (o nome engana: vale para
tarôs e planetas também). Toda carta criada entra nela na hora (`Card:set_ability`) e sai quando some
(`Card:remove`, se você não tiver outra cópia). É por isso que um pacote nunca repete carta.

### 4.2 A caixa de areia (sandbox)

O mod **não chama** `create_card`: ela cria um objeto `Card` de verdade (sprite, som, "descoberta" na coleção,
conquistas) e gastaria as tags da loja. Em vez disso, `Peek.sandbox` faz:

```lua
local saved_pr, saved_uj = copy(G.GAME.pseudorandom), copy(G.GAME.used_jokers)   -- 1. guarda os DOIS
local ok, res = pcall(fn)                                                       -- 2. refaz a receita
put_back(G.GAME.pseudorandom, saved_pr)                                         -- 3. devolve tudo
put_back(G.GAME.used_jokers, saved_uj)                                          --    (e apaga o que foi criado)
```

E dentro dela a receita usa **as funções do próprio jogo** — `get_current_pool` (a lista de cartas possíveis),
`pseudorandom_element` (sorteia nela), `pseudoseed`, `pseudorandom`, `poll_edition`, `SMODS.poll_seal` — na mesma
ordem que o jogo usa. A receita de cada pacote é a do próprio pacote (`center:create_card`, no
`src/game_object.lua` do Steamodded): é ela que rola o Omen Globe (Arcana com Espectral), o Telescope (Celestial com
o planeta da sua mão mais jogada) e a edição/selo/aprimoramento das cartas do pacote Padrão.

### 4.3 O que o mod prevê com isso

- **Pacotes da loja, antes de comprar** (`Peek.pack`): as cartas, na ordem. Dois pacotes do mesmo tipo usam os mesmos
  fluxos: a previsão vale para **o primeiro que você abrir**.
- **Os próximos 3 rerolls** (`Peek.rerolls`): `create_card_for_shop` (em `functions/UI_definitions.lua` e
  `lovely/shop.toml`) sorteia o **tipo** da carta pelo fluxo `cdt1` (coringa, tarô, planeta... pelas taxas da loja),
  depois a carta com o sufixo `sho`. Um reroll **primeiro tira** as cartas da prateleira (elas voltam a poder sair) e
  depois dá `joker_max` cartas novas.
- **A próxima loja** (`Peek.next_shop`): o mesmo, numa prateleira vazia. Depois de um Chefe a ante já subiu quando a
  loja abre, então os fluxos são os da ante seguinte.
- **O que a tag de pular entrega** (`Peek.tag`): Charm/Meteoro/Etérea/Bufão/Padrão abrem um pacote na hora; Top-up
  cria até 2 Comuns na hora; Rara/Incomum põem um coringa grátis na próxima loja.
- **O coringa que A Alma, o Julgamento e o Espectro criam** (`Peek.created`): o Lendário da Alma sai do fluxo
  `Joker4`, **sem a ante no nome** — vale para a run inteira (a 1ª Alma da seed dá o mesmo Lendário em qualquer
  ante, a não ser que você já tenha esse Lendário; a edição dele, essa sim, depende da ante).

### 4.4 Como o motor usa

- Um pacote conhecido vale **exatamente o que você pegaria dele** (`engine/packs.lua` → `P.known_value` pergunta ao
  mesmo conselheiro que decide quando o pacote está aberto) — e não sofre mais o desconto de "aposta" de quem está
  com pouco dinheiro.
- O reroll vale **o melhor coringa que os próximos rerolls realmente trazem** (`engine/shop_advisor.lua` →
  `seer_reroll_best`), se der para comprá-lo depois, descontando o preço dos rerolls extras.
- A tag vale o que entrega (`engine/tags.lua` → `Tags.known_value`), e A Alma/Julgamento/Espectro valem o coringa que
  criam (`engine/consumable_value.lua` → `CV.seer_joker_frac`).

### 4.5 Uma previsão não pode alimentar a si mesma

Um erro real que apareceu no jogo e ensina bastante: o Julgamento vale o coringa que vai criar. Se esse coringa é a
Bola 8, ela vale pelos tarôs aleatórios que cria — e a média dos tarôs inclui o Julgamento, que com a previsão vale a
Bola 8 de novo... uma conta sem fim, e o Lua desiste com `stack overflow`. A correção (`Seer.inner` em
`engine/seer.lua`): o coringa criado é avaliado numa **cópia do estado sem as previsões**. Lá dentro o Julgamento
volta a valer a média, e a conta termina depois de um nível. A cópia leva duas marcas (`seer_inner`,
`seer_pack_inner`) que passam junto quando o motor copia o estado, então funciona sem nenhuma variável global — o que
importa porque o motor roda fatiado numa corrotina.

### 4.6 A autoconferência

`BES.seer_check_shop` (em `main.lua`) guarda cada previsão e compara quando a coisa acontece: o pacote que abriu
(o Steamodded guarda qual foi em `SMODS.OPENED_BOOSTER`), a prateleira depois de um reroll (o contador de rerolls da
run, `G.GAME.round_scores.times_rerolled`, subiu 1) e a primeira prateleira de uma loja nova. Duas falhas, mais
falhas que acertos → aquela previsão é desligada e o painel avisa.

## 5. Nível 4 — a mão inicial da próxima rodada

A versão anterior deste guia dizia que a próxima rodada não dava para prever. **Dá** — e a explicação é ótima para
aprender. O embaralhamento do começo da rodada é `pseudoshuffle(cartas, semente)`, e ele faz **duas** coisas:

```lua
table.sort(list, function(a, b) return a.sort_id < b.sort_id end)   -- 1. põe as cartas numa ordem fixa
for i = #list, 2, -1 do                                             -- 2. Fisher-Yates com a semente
  local j = math.random(i); list[i], list[j] = list[j], list[i]
end
```

O passo 1 apaga a ordem em que as cartas estavam: o resultado só depende de **quais** cartas estão no baralho e do
próximo valor do fluxo `nr<ante>`. Então `Peek.next_round` copia a lista, chama o `pseudoshuffle` do próprio jogo
na cópia (dentro da caixa de areia) e lê a ordem de compra. Na loja e na escolha do blind o painel mostra a mão
inicial da próxima rodada, e no começo da rodada o mod confere (`BES.seer_check_round`).

Exceção: o **Marble Joker** põe uma carta de Pedra no baralho ao selecionar o blind, **antes** do embaralhamento —
com ele, o mod não prevê.

## 6. Curiosidades que caem disso

- **Pular o Small Blind não "perde" a loja dele.** A loja depois do Big Blind sai dos mesmos fluxos (mesma ante),
  então mostra as cartas que a loja do Small mostraria. A mão inicial também: a rodada do Big usa o valor de `nr1`
  que a do Small usaria. Pular o **Big** Blind é diferente: a próxima loja vem depois do Chefe, já na ante seguinte.
- **Abrir um pacote quase não muda os rerolls** (e rerolar quase não muda os pacotes): os fluxos são diferentes
  (`ar1` × `sho`). Só a carta que você **guarda** conta: ela fica "fora" e não pode sair na loja.
- **Comprar um coringa muda o próximo pacote Bufão**: ele passa a estar "fora" e não pode sair.

## 7. O que ainda não dá para prever

- Quando **outro mod** liga o sistema de pesos de sorteio do Steamodded (`SMODS.optional_features.object_weights`):
  a receita muda inteira. O painel avisa.
- **Pacotes de outros mods** e o reroll quando uma **Tag Rara/Incomum** ainda vai trocar uma carta da loja.
- Coisas que acontecem **entre** a previsão e o fato: um tarô criado pela Cartomante ou pela 8 Ball e guardado muda
  quais tarôs a próxima loja pode ter; a Hallucination cria um tarô quando você abre um pacote (raramente muda o
  pacote). É para isso que existe a autoconferência.
- Lojas e rodadas **depois da próxima**, e o voucher da próxima ante.

## 8. Onde mexer para aprender

| Arquivo | O que tem |
|---|---|
| `core/state_extraction.lua` | o arquivo que lê o estado do jogo (`G`): `peek_rolls`, `peek_next_boss` |
| `core/seer_peek.lua` | a caixa de areia e as receitas: pacotes, rerolls, próxima loja, tags, Alma, próxima rodada |
| `engine/seer.lua` | ordem conhecida, rolagens por fluxo (puro, testável sem o jogo) |
| `engine/hand_eval.lua` | a pontuação; procure `seer_effect` |
| `engine/packs.lua`, `engine/shop_advisor.lua`, `engine/tags.lua` | onde as previsões viram decisão (procure `seer`) |
| `main.lua` | liga/desliga (F4), autoconferência, painel "Futuro" |
| `tests/standin_game.lua` | um "jogo de mentira" com as funções de sorteio e as receitas, e o jogo "de verdade" para comparar |
| `tests/test_seer.lua`, `tests/test_seer_shop.lua` | os testes (`lua5.4 tests/runner.lua`) |

Dica para experimentar: com um mod de console (como o DebugPlus) ou um `print` temporário no código,
`G.GAME.pseudorandom` mostra todos os fluxos que a run já usou (procure `Tarotar1`, `cdt1`, `Joker4`...), e
`G.deck.cards[#G.deck.cards].base` é a próxima carta que você vai comprar.
