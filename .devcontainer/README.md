# .devcontainer — Configuração do ambiente dos laboratórios

Esta pasta contém a definição do ambiente de desenvolvimento usado em todos os laboratórios da disciplina **Cloud Engineering**. A ideia é simples: qualquer aluno, em qualquer máquina, consegue abrir um ambiente idêntico ao do professor em segundos — sem instalar nada localmente.

> [!TIP]
> Se você é aluno e só quer começar os laboratórios, vá direto para o [setup da aula 01](../01-create-codespaces/README.md). Este README é para quem quer entender **como** o ambiente é construído.

---

## O que é um Dev Container?

Um **Dev Container** é uma especificação do projeto [Development Containers](https://containers.dev/) que descreve, em um arquivo JSON, todo o ambiente necessário para desenvolver um projeto: sistema operacional base, ferramentas instaladas, extensões do editor, variáveis de ambiente e scripts de inicialização.

Esse mesmo arquivo é consumido por:

- **GitHub Codespaces** — ambiente cloud usado na disciplina
- **VS Code Remote - Containers** — para rodar localmente em Docker
- **JetBrains Gateway** e outras IDEs compatíveis

Ou seja: um único arquivo garante reprodutibilidade total do ambiente em qualquer plataforma que suporte a spec.

---

## Por que isso importa na disciplina?

Durante a disciplina você vai executar comandos da AWS CLI, rodar scripts Python, executar Terraform, usar Serverless Framework e interagir com vários serviços AWS. Sem um ambiente padronizado, teríamos:

- versões diferentes de cada ferramenta por aluno
- problemas de permissão e dependências no Windows/macOS/Linux
- tempo de aula perdido com "no meu computador não funciona"

Com o Dev Container desta pasta, todos os alunos recebem:

- ✅ Ubuntu como base
- ✅ Python 3, AWS CLI, Terraform, Node LTS, Git e Docker-in-Docker
- ✅ Serverless Framework v3 pré-instalado
- ✅ Extensões essenciais do VS Code já instaladas
- ✅ Região AWS `us-east-1` configurada por padrão

---

## Arquivos desta pasta

| Arquivo | Função |
|---------|--------|
| [`devcontainer.json`](devcontainer.json) | Manifesto principal. Define a imagem base, features instaladas, extensões do VS Code e o comando pós-criação. |
| [`script.sh`](script.sh) | Script executado automaticamente após a criação do container. Instala o Serverless Framework e copia a config padrão da AWS. |
| [`config`](config) | Arquivo de configuração padrão da AWS CLI (região `us-east-1`, output `json`). Copiado para `~/.aws/config` pelo `script.sh`. |

---

## Anatomia do `devcontainer.json`

Abaixo, cada bloco da configuração e o porquê dele estar ali.

### 1. Identidade e imagem base

```json
"name": "FIAP Lab",
"image": "mcr.microsoft.com/devcontainers/base:ubuntu"
```

O `name` é o rótulo que aparece na tela de criação do Codespaces (você seleciona `FIAP Lab` como `Dev container configuration`). A `image` é a imagem oficial do Microsoft com Ubuntu enxuto, otimizada para ser ponto de partida de Dev Containers.

### 2. Features — ferramentas injetadas na imagem

```json
"features": {
  "ghcr.io/devcontainers/features/python:1": { "version": "3" },
  "ghcr.io/devcontainers/features/git:1": {},
  "ghcr.io/devcontainers/features/aws-cli:1": {},
  "ghcr.io/devcontainers/features/terraform:1": {},
  "ghcr.io/devcontainers/features/node:1": { "version": "lts" },
  "ghcr.io/devcontainers/features/docker-in-docker:2": {}
}
```

**Features** são pacotes reutilizáveis publicados no registry `ghcr.io/devcontainers`. Cada um adiciona uma ferramenta configurada corretamente na imagem, sem precisar escrever Dockerfile. Aqui instalamos:

- **Python 3** — para scripts Python e notebooks
- **Git** — versionamento
- **AWS CLI** — interação com todos os serviços AWS dos laboratórios
- **Terraform** — provisionamento de infraestrutura
- **Node LTS** — necessário para o Serverless Framework
- **Docker-in-Docker** — permite rodar containers dentro do Codespaces (útil em labs futuros)

> [!NOTE]
> A sintaxe `feature:1` é versionamento por major. Você recebe a última versão estável do major `1` da feature. Isso evita quebras de versão mantendo compatibilidade com correções recentes.

### 3. Extensões do VS Code

```json
"customizations": {
  "vscode": {
    "extensions": [
      "ms-python.python",
      "aws-scripting-guy.cform",
      "hashicorp.terraform",
      "github.copilot",
      "redhat.vscode-yaml",
      "fradolph.serverless-snippets"
    ]
  }
}
```

Assim que o Codespaces sobe, o VS Code já vem com as extensões essenciais: Python, CloudFormation, Terraform, Copilot, YAML e snippets do Serverless. Não é preciso instalar nada manualmente.

### 4. Comando pós-criação

```json
"postCreateCommand": "chmod +x /workspaces/fiap-cloud-engineering/.devcontainer/script.sh && bash /workspaces/fiap-cloud-engineering/.devcontainer/script.sh"
```

Depois que o container é criado, o `postCreateCommand` é executado uma única vez. Ele dá permissão de execução ao [script.sh](script.sh) e o roda. É nesse momento que o Serverless Framework é instalado e o `~/.aws/config` é preparado.

### 5. Configurações do terminal

```json
"settings": {
  "terminal.integrated.defaultProfile.linux": "bash"
}
```

Garante que o terminal integrado do VS Code use `bash` por padrão — importante porque os comandos dos laboratórios assumem sintaxe bash.

---

## O que o `script.sh` faz?

```bash
#!/bin/bash
set -eux
sudo apt-get update -y
npm i serverless@3.39.0 -g
mkdir -p ~/.aws/
cp /workspaces/fiap-cloud-engineering/.devcontainer/config ~/.aws/config
```

Passo a passo:

1. **`set -eux`** — falha rápido se qualquer comando der erro (`-e`), trata variáveis não definidas como erro (`-u`) e mostra cada comando antes de executar (`-x`). Boa prática em scripts de provisionamento.
2. **`apt-get update`** — atualiza os índices de pacotes do Ubuntu.
3. **`npm i serverless@3.39.0 -g`** — instala globalmente o Serverless Framework v3 (v4 mudou o modelo de licenciamento, por isso fixamos v3).
4. **`mkdir -p ~/.aws/`** — garante que a pasta exista.
5. **`cp .../config ~/.aws/config`** — copia a configuração padrão de região/output para o perfil default da AWS CLI.

> [!IMPORTANT]
> O `script.sh` **não** copia credenciais. Isso é intencional — credenciais são individuais por aluno e saem do AWS Academy. O aluno precisa colar o `~/.aws/credentials` manualmente a cada sessão. Veja o [setup da aula 01](../01-create-codespaces/README.md) para o passo a passo.

---

## Como o Codespaces usa isso

Fluxo resumido:

```
1. Aluno clica em "New codespace" no repositório
         │
         ▼
2. GitHub lê este .devcontainer/devcontainer.json
         │
         ▼
3. Instancia a imagem base Ubuntu
         │
         ▼
4. Aplica as features (Python, AWS CLI, Terraform, Node, Docker)
         │
         ▼
5. Instala as extensões do VS Code listadas
         │
         ▼
6. Executa o postCreateCommand → script.sh
         │
         ▼
7. Codespaces pronto, com terminal bash aberto em /workspaces/...
```

Todo esse processo leva alguns minutos na primeira criação. Nas próximas vezes que você **iniciar** (não recriar) o Codespaces, o ambiente já estará pronto em segundos — as features e extensões ficam persistidas no container.

---

## Como atualizar o ambiente

Se precisar adicionar uma ferramenta ou extensão para todos os alunos, siga este fluxo:

1. Edite o [`devcontainer.json`](devcontainer.json) adicionando a feature ou extensão desejada.
   - Para ferramentas novas, consulte o catálogo oficial em [containers.dev/features](https://containers.dev/features).
   - Para extensões, copie o ID exato do marketplace do VS Code.
2. Se precisar de lógica adicional na inicialização, ajuste o [`script.sh`](script.sh).
3. Faça commit e push da alteração.
4. Os alunos precisam **recriar** o Codespaces (ou usar `Codespaces: Rebuild Container` via Command Palette) para que as mudanças sejam aplicadas.

> [!WARNING]
> Mudanças no `devcontainer.json` **não** são aplicadas automaticamente em Codespaces já existentes. Sempre avise os alunos para recriarem o ambiente após atualizações significativas.

---

## Rodando o Dev Container localmente (opcional)

Para quem preferir rodar em Docker local em vez do Codespaces:

1. Instale [Docker Desktop](https://www.docker.com/products/docker-desktop/) e a extensão [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) do VS Code.
2. Clone o repositório.
3. Abra a pasta no VS Code e selecione `Reopen in Container` na notificação que aparece (ou use `F1 → Dev Containers: Reopen in Container`).
4. O VS Code executa o mesmo fluxo do Codespaces, só que localmente.

> [!TIP]
> A recomendação da disciplina é usar o Codespaces. Ele elimina variáveis de instalação local e oferece 120h mensais gratuitas em contas GitHub pessoais, mais que suficiente para a disciplina — desde que você **pare** o ambiente ao final de cada aula.

---

## Referências

- [Dev Containers Specification](https://containers.dev/)
- [GitHub Codespaces Docs](https://docs.github.com/en/codespaces)
- [Catálogo de Features](https://containers.dev/features)
- [devcontainer.json reference](https://containers.dev/implementors/json_reference/)
- [Setup da disciplina (aula 01)](../01-create-codespaces/README.md)
