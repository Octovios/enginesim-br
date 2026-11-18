# Engine Sim BR — o "Stockfish" do Balatro, em português

Mod para Balatro (Steamodded + Lovely) que lê o jogo ao vivo e mostra **a melhor jogada a cada momento**, como as
extensões de xadrez: o que jogar, o que descartar, o que comprar/vender na loja, qual carta pegar em cada pacote,
quando usar cada tarô/planeta/espectral e se vale pular o blind — **sempre com o porquê**.

É um fork aprimorado e traduzido do [EngineSim de Anto640](https://github.com/Anto640/balatro-engine-sim)
(licença MIT). A "IA" é o próprio motor de simulação: ele reproduz a pontuação do Balatro, simula milhares de mãos
com o seu baralho real (Monte-Carlo) e compara as opções — o mesmo princípio de um motor de xadrez.

> Projeto de fã, sem ligação com a LocalThunk ou a Playstack. Não inclui código nem arte do jogo. É um assistente
> para jogo solo: não use em partidas competitivas (Balatro Multiplayer etc.).

## O que este fork acrescenta

| Área | O que mudou |
|---|---|
| **Português** | Painel, motivos, tags nas cartas, menu e configurações em PT-BR. Nomes de cartas, coringas, tarôs, planetas, tags e mãos aparecem **como o jogo mostra no seu idioma**. Cartas: `Ke` = Rei de espadas, `10o` = 10 de ouros (e/c/p/o = espadas/copas/paus/ouros). |
| **Ficha (stake)** | O motor agora sabe a ficha da run: na **Ficha Vermelha+** o Small Blind paga **$0**; na **Ficha Verde+/Roxa+** os blinds crescem mais rápido (o ritmo da run é calculado com a meta certa); avisa de coringas **Eternos / Perecíveis / Alugados**. |
| **Baralho** | **Plasma**: a pontuação equilibra fichas e mult (+Fichas vale tanto quanto +Mult) e os blinds são x2. **Verde**: sem juros, $2 por mão e $1 por descarte que sobram. **Abandonado** (ou qualquer baralho sem realeza): builds de Rei/Rainha/realeza aparecem como **inviáveis**. **Xadrez**: só 2 naipes, flush favorecido. **Errático**: lê o baralho real. |
| **Pular ou jogar** | Compara a tag com o valor **real** de jogar: recompensa da ficha, visita à loja, juros, mãos que sobram, coringas de dinheiro e — novidade — **coringas que crescem jogando** (Green Joker, Runner, Wee Joker, Lucky Cat, Supernova, Castle, Yorick…), os que **perdem valor** jogando (Ice Cream, Popcorn, Ramen, Gros Michel…), Madness ao selecionar o blind e o **Throwback**, que cresce quando você pula. Tudo detalhado no painel. |
| **A Morte (Death)** | Diz **qual carta vira qual** e, se a ordem na mão estiver errada, manda **arrastar a carta para a ESQUERDA** antes de usar. As tags nas cartas mostram `1 VIRA` / `2 MODELO` e `<< ARRASTE` em vermelho. |
| **Builds** | 23 builds catalogadas (flush por naipe, sequência, pares, full house, quadra, quina, realeza, Reis de Aço/Baron+Mime, Fibonacci, números pares, Hack, Sorte, Vidro, Pedra, Dinheiro, Descartes, Planetas, Repetições, Carta Alta). Cada uma é avaliada pelo **seu baralho**, pelos coringas que você tem, pelos que **estão na loja agora** e pelos que **já apareceram na loja nesta run**. O painel mostra as 3 melhores com o que você já tem e o que procurar. |
| **Forçar build (F3)** | Escolha uma build para forçar (no início ou no meio da run). O motor passa a **puxar compras, vendas, pacotes, planetas e tarôs** para ela: peças principais ganham prioridade e não são vendidas, a Morte/Força/Enforcado miram o naipe/valor da build, os tarôs certos (ex.: O Carro / The Chariot, que cria cartas de Aço, para Reis de Aço) sobem de valor. Dá para deixar uma build padrão para toda run nova nas configurações. |
| **Ordem dos coringas** | Calcula a melhor ordem dos coringas sobre várias mãos típicas do seu baralho (quem soma Fichas/Mult antes, quem multiplica depois, copiadores no lugar certo) e mostra na escolha do blind e na loja, com números em cima dos coringas. O autoplay arruma sozinho. Na jogada, reordena mesmo quando a mão já vence (vale para as próximas mãos). |
| **Observatório** | O voucher Observatório agora é calculado (x1.5 por planeta guardado da mão jogada) e o motor para de mandar usar esses planetas. |
| **Perkeo** | Cópias Negativas de consumíveis passaram a ser lidas do jogo. |
| **Como um motor de xadrez** | Além do melhor lance, o painel mostra **outras opções** (as próximas melhores linhas) e o detalhamento do cálculo. |

## Novidades

- **0.7.2** — ordem permanente dos coringas (somar antes, multiplicar depois), sugerida na escolha do blind e na loja
  e aplicada pelo autoplay; na jogada, os coringas são reordenados mesmo quando a mão já vence.
- **0.7.1** — coringa **Negativo** não precisa de vaga: o motor não manda mais vender um coringa para comprá-lo
  (bug herdado do original). **Quina / Flush Five forçado** mira numa carta exata (valor + naipe): A Morte e o
  Cryptid copiam essa carta, pacotes Padrão priorizam cópias dela e o baralho é afinado com mais força (ideal ~25).

## Instalação

1. Instale o [Lovely](https://github.com/ethangreen-dev/lovely-injector) e o [Steamodded](https://github.com/Steamodded/smods)
   (ou use o r2modman, que instala os dois).
2. **Remova o EngineSim original** se ele estiver instalado — os dois não podem rodar juntos (o Steamodded avisa do conflito).
3. Copie a pasta do mod (o zip já vem com a pasta `EngineSimBR/` contendo `main.lua`, `your_mod.json`,
   `config.lua`, `core/`, `engine/`, `model/`, `ui/`, `util/`) para:
   - Windows: `%AppData%\Balatro\Mods\`
   - macOS: `~/Library/Application Support/Balatro/Mods/`
   - Linux (Proton): `~/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/`
4. Abra o jogo. Em **Mods → Engine Sim BR → Config** dá para escolher o idioma (Português é o padrão), a política de
   pulos e a build padrão.

**r2modman:** `python tools/package_r2.py` gera `dist/...zip` para "Import local mod".

## Teclas

| Tecla | Ação |
|---|---|
| **F3** | Menu de builds: escolher uma build para forçar (fora da run: define a build padrão) |
| **F9** | Mostrar / esconder o painel |
| **F11** | Autoplay: o motor joga sozinho |
| **F6** | Reinício automático da run (com o autoplay) |
| **F5** | Marcar uma jogada ruim (salva as últimas decisões para análise) |
| **F8** | Recalcular agora (com simulação completa) |

## Como ler o painel

O painel fica no topo da barra esquerda do jogo. A linha grande é o lance recomendado (ex.: `Jogar Ke Kc 7p 7o 2e`
ou `Usar A Morte — antes arraste 3p para a ESQUERDA de Ke; 3p vira cópia de Ke`). As tags embaixo mostram a
pontuação prevista contra o que falta, a confiança e o custo. **Passe o mouse no painel** para ver:

- o **porquê** detalhado (ex.: o cálculo completo de pular vs. jogar);
- **outras opções** — as próximas melhores jogadas;
- as **builds sugeridas** (ou a build forçada, com o que falta);
- **"Nesta run"**: o que a ficha e o baralho mudam.

No jogo, tags coloridas marcam exatamente a carta, o item da loja ou o botão recomendado.

## Exemplos do que ele considera

- **Ficha Vermelha, Small Blind, tag fraca:** "Jogue: a Tag de Cupom (~$8) vale menos que jogar (~$14). Mesmo sem
  recompensa (Ficha Vermelha), a loja e seus coringas fazem jogar valer mais. (Green Joker cresce +2 Mult.)"
- **Baralho Abandonado com Baron na mão:** "Reis de Aço (Baron + Mime): inviável aqui (sem cartas de realeza no
  baralho)" — e a build nunca é sugerida.
- **A Morte com a mão ordenada do maior para o menor:** o 3 está à direita do Rei, então o painel manda arrastar o 3
  para a esquerda antes de usar; as tags mostram `<< ARRASTE / 1 VIRA` no 3 e `2 MODELO` no Rei.
- **Forçando "Flush de Copas":** Bloodstone, Lusty Joker, The Tribe e Smeared Joker sobem na loja; O Sol / The Sun
  (converte para Copas) ganha valor e A Estrela / The Star (Ouros) perde; O Enforcado / The Hanged Man corta cartas
  que não são de Copas; Júpiter (Flush) é priorizado.

## Limitações honestas

- O jogo não pôde ser executado no ambiente onde este fork foi feito: toda a lógica foi testada sem o jogo
  (2.000 testes automáticos), mas campos lidos do jogo marcados `-- VERIFY` em `core/state_extraction.lua` (ficha,
  recompensas, nomes traduzidos) só se confirmam rodando no Balatro. Se algo aparecer errado, aperte **F5** e
  verifique o log do Lovely.
- Jokers de outros mods não são modelados (pontuam zero no cálculo; o log avisa).
- O motor vê cartas viradas para baixo por alguns chefes (vantagem conhecida do original).
- Forçar uma build é uma escolha sua: se a build não aparecer, o motor ainda tenta sobreviver, mas ele vai priorizar
  as peças dela mesmo quando outra opção pontuaria mais agora.

## Desenvolvimento

O motor é **puro**: só `core/state_extraction.lua` lê o jogo; todo o resto roda e é testado sem o Balatro.

```sh
lua5.4 tests/runner.lua      # testes unitários (Lua 5.4; o jogo usa LuaJIT, também compatível)
luajit tests/runner_sim.lua  # testes do simulador (demorados)
```

Arquivos novos deste fork: `engine/run_context.lua` (ficha/baralho), `engine/scaling_growth.lua` (crescimento dos
coringas), `engine/archetypes.lua` e `engine/build_advisor.lua` (builds), `ui/build_menu.lua` (F3),
`util/i18n.lua`, `util/i18n_msgs.lua`, `util/lang_pt_br.lua` (tradução), `tests/test_br.lua`.

## Créditos

- Motor original, simulador e a maior parte do código: **Anto640** — EngineSim, licença MIT (veja `LICENSE`).
- Fork Engine Sim BR: tradução, ficha/baralho, pular vs. jogar com crescimento de coringas, ordem da Morte, planejador
  e modo de forçar builds, Observatório.
