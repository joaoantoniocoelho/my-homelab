# Gerenciamento de máquinas virtuais (libvirt) no Homelab.app

- **Slug:** vm-management
- **Origem:** pedido ad hoc (execução autônoma ponta a ponta autorizada pelo usuário na conversa)
- **Status:** implementado

## Contexto
O servidor Ubuntu roda uma VM Kali (KVM/libvirt, `qemu:///system`, NAT `default`, XRDP). Hoje o fluxo exige
comandos manuais: `virsh start`, túnel `ssh -N -L`, abrir o Windows App e desligar via `sudo systemctl poweroff`.
O ACPI (`virsh shutdown`) não desliga o Kali de forma confiável e não há qemu-guest-agent configurado.

## Objetivo e critérios de aceite
- [ ] Descobrir VMs do libvirt pela conexão SSH existente, sem fixar a VM no código.
- [ ] Exibir estado, vCPUs, RAM, disco, endereço e prontidão (SSH/RDP) separando "VM ligada" de "convidado pronto".
- [ ] Ligar, desligar com segurança, reiniciar e atualizar; forçar desligamento só com confirmação explícita.
- [ ] "Abrir desktop" em um clique: liga se preciso, espera o XRDP responder, abre túnel loopback, abre o cliente RDP.
- [ ] Túnel gerenciado: só loopback, `ExitOnForwardFailure`, detecção de porta ocupada, sem processos órfãos,
      sem matar SSH de terceiros, sem duplicar em cliques repetidos.
- [ ] Fechar o RDP ou o app não desliga a VM.
- [ ] Testes automatizados (Swift e Python) e README atualizado.

## Abordagem
- **Remoto:** novo script `vm.py` (mesmo modelo do `collector.py`: enviado via `python3 -c`, nunca instalado),
  que chama `virsh` com listas de argumentos (sem shell) e `--domain` explícito. Uma única conexão SSH por
  atualização lista domínios (`domstats`), endereços (`domifaddr --source lease|arp`) e testa prontidão de
  dentro do servidor: banner `SSH-` e handshake X.224 do RDP. Resposta JSON com os mesmos marcadores do coletor.
- **Core (`HomelabCore`):** modelos e parsing, `VirtualMachineConfig` (persistido por VM), `LibvirtClient`,
  `GuestClient` (SSH no convidado via `-J` pelo servidor), `SSHTunnel`/`TunnelManager` (supervisão de processo,
  registro de PID para limpar órfãos), `RDPProbe` (X.224 pelo túnel), `RDPFile`, e o actor `VMOperations`
  que orquestra os fluxos com dependências injetáveis e single-flight por VM.
- **App:** nova tela "Máquinas virtuais", `MachinesModel` (estado de UI), integração com terminal para SSH no
  convidado e para o `sudo` interativo de desligamento, linha compacta no menu bar.
- **Cliente RDP:** gerar um `.rdp` (sem credenciais) e abrir com o app dono do tipo (Windows App:
  `com.microsoft.rdc.macos`, que declara `.rdp` com `LSHandlerRank=Owner`). Trocar de cliente = trocar bundle id.

## Desligamento seguro
1. SSH não interativo no convidado: `systemctl --no-ask-password poweroff`, depois `sudo -n systemctl poweroff`
   (funciona se houver regra polkit/sudoers restrita configurada pelo usuário).
2. Se o convidado pedir autenticação: o app oferece abrir uma aba de terminal com `sudo systemctl poweroff`;
   a senha vai direto do teclado para o `sudo` via PTY, nunca é armazenada. O app segue observando o libvirt.
3. Se o convidado não responder por SSH: pedido ACPI (`virsh shutdown --mode acpi`) e espera.
4. "Forçar desligamento" (`virsh destroy`) só pelo menu, com confirmação destrutiva.

## Arquivos afetados
- `Sources/HomelabCore/vm.py` — helper remoto.
- `Sources/HomelabCore/VirtualMachines.swift`, `Tunnel.swift`, `VMOperations.swift` — core.
- `Sources/Homelab/MachinesModel.swift`, `MachinesPage.swift`, `RemoteDesktopLauncher.swift` — app.
- `AppModel.swift`, `ContentView.swift`, `HomelabApp.swift`, `MenuBarDashboard.swift`, `TerminalSession.swift` — integração.
- `Package.swift` — recurso `vm.py`.
- `Tests/` — testes Swift e Python. `README.md` — documentação.

## Plano de testes
- Python: parsing de `domstats`/`domifaddr`, fallback, libvirt indisponível, probes X.224/SSH com socket falso,
  validação de nomes/endereços, ações idempotentes.
- Swift: decodificação/estados, comandos e quoting, config/defaults/validação, argumentos do túnel (loopback,
  ExitOnForwardFailure, sem multiplexação), ciclo de vida do processo, porta ocupada, reaper de órfãos,
  fluxos de abrir desktop (VM ligada/desligada/timeout/RDP indisponível), desligamento (aceito/autenticação/ACPI/timeout),
  cliques duplicados e cancelamento.

## Riscos
- Comportamento do Windows App ao abrir `.rdp` pode mudar entre versões (documentado).
- Sem guest agent, "pronto" é inferido por portas (SSH/RDP) — documentado.

## Log de decisões
- 2026-10-11 — Plano registrado sem pausa para aprovação — o usuário pediu execução autônoma ponta a ponta.
- 2026-10-11 — `.rdp` em vez de URL `rdp://` — o tipo de documento é o mecanismo declarado e verificável no Info.plist; a URL não é necessária.
- 2026-10-11 — Não instalar qemu-guest-agent nem regra sudoers — muda a VM/infra; documentado como opcional.
- 2026-10-11 — Reiniciar = desligamento seguro + ligar — reutiliza o caminho confiável de desligamento.
- 2026-10-11 — Túnel permanece ativo até o usuário encerrar, a VM desligar ou o app sair — reabrir o desktop fica instantâneo.
- 2026-10-11 — Verificado com o Windows App 11.4.3: abrir o `.rdp` gerado conecta imediatamente pelo túnel (conexão ESTABLISHED em 127.0.0.1:3390).
- 2026-10-11 — Tela chamada "VMs" (o nome longo quebrava a sidebar); a descrição completa fica no subtítulo.
- 2026-10-11 — Kali exige senha no `sudo` (verificado com `sudo -n true`), então o caminho padrão de desligamento é o terminal do app.
- 2026-10-11 — Teste real: o desligamento via sudo funcionou, mas o Kali levou minutos com SSH/XRDP já parados e o libvirt ainda "running". Agora a VM fica "Desligando" desde o pedido até o libvirt confirmar, sem ser confundida com boot.
