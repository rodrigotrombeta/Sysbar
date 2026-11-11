# Sysbar

App de barra de menus do macOS que mostra o painel **System Stats** do
[oMLX](https://github.com/jundot/omlx) (CPU E/P-cores, térmico, load avg,
uptime, GPU, memória da GPU e memória), com um ícone animado no estilo do
[Stats](https://github.com/exelban/stats).

## Compilar e instalar

```bash
./build.sh            # gera build/Sysbar.app
./build.sh install    # copia para /Applications e abre
```

Requer macOS 14+ e as Command Line Tools (Swift). Não precisa de Xcode.

## Ícone

No menu do app:

- **Métricas no ícone** — escolha uma ou mais: CPU (total), E-cores, P-cores,
  GPU, memória da GPU, RAM. Cada uma vira um mini widget que se move com o uso.
- **Estilo do ícone** — gráfico de linha, barra, porcentagem ou gráfico +
  porcentagem; opção de mostrar o rótulo (CPU/GPU/RAM).
- **Cores** — monocromático (segue o tema da barra), cor da métrica ou por
  utilização (verde → laranja → vermelho).
- **Intervalo de atualização** — 0,5 s a 5 s.
- **Abrir ao iniciar sessão** — funciona melhor com o app em /Applications.

`Sysbar --preview <pasta>` grava PNGs de todos os estilos e do painel.

## Créditos

`SystemStatsSampler.swift` e `SystemStatsPanels.swift` são adaptados do oMLX
(Apache License 2.0, ver `LICENSE`). Só usa APIs públicas (Mach, IOKit,
vm_statistics64); não precisa de sudo.
