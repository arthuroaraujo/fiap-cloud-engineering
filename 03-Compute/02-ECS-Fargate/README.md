# 03.2 - Containers na AWS com ECS + Fargate

**Antes de começar, execute os passos abaixo para configurar o ambiente caso não tenha feito isso ainda na aula de HOJE: [Preparando Credenciais](../../01-create-codespaces/Inicio-de-aula.md)**

Todos os comandos `bash` abaixo rodam no **terminal do GitHub Codespaces**. Os passos de console AWS estão sinalizados explicitamente.

> [!WARNING]
> **Pré-requisitos — confira antes de começar:**
>
> - [ ] Codespace aberto e sincronizado com credenciais da AWS Academy (rodou o [Preparando Credenciais](../../01-create-codespaces/Inicio-de-aula.md) na aula de hoje).
> - [ ] `aws sts get-caller-identity` retorna um `Account` e um `Arn` sem erro.
> - [ ] `aws s3 ls | grep base-config-` lista exatamente **um** bucket do seu RM (se listar zero, o setup inicial não foi feito; se listar mais de um, confirme qual é o da aula de hoje).
> - [ ] `docker version` responde sem erro (o Codespaces já traz Docker instalado).
> - [ ] `terraform -version` retorna >= 1.3.
>
> **O que você vai fazer:** provisionar ECS Fargate com Terraform, buildar e publicar uma imagem Docker no ECR, validar que a aplicação sobe no Fargate e consumir o endpoint público. **Tempo estimado: 45 minutos.**

Neste laboratório você coloca em prática o ciclo completo de um deploy moderno baseado em containers na AWS. A aplicação é trivial de propósito — um "hello world" em Node.js na porta 3000 — para que toda a atenção fique no que importa: como o **ECS Fargate** orquestra containers sem que você provisione instâncias EC2, e como o **ECR** entra como registro de imagens privado integrado ao IAM.

O fluxo que você vai exercitar é o mesmo que um time de engenharia usaria em produção, só que em escala de aula: infraestrutura como código primeiro, build e push da imagem depois, validação e limpeza por último.

## Principais pontos de aprendizagem

- Diferença prática entre **ECS** (orquestrador), **Fargate** (modo de execução sem servidor) e **ECR** (registro privado de imagens).
- Anatomia de uma **task definition** Fargate: CPU/memória, `network_mode=awsvpc`, `execution_role_arn`.
- Ciclo `docker build` → `docker tag` → `docker push` contra um registro privado da AWS autenticado via IAM.
- Por que o serviço ECS é um *loop de controle*: ele recria a task sozinho quando a imagem aparece no ECR.
- Diagnóstico go/no-go em cada fronteira (Terraform aplicou? imagem subiu? task virou `RUNNING`? endpoint responde?).

## O que você terá ao final

Uma aplicação Node.js rodando em um container Fargate com IP público, acessível pelo navegador ou via `curl`, com todo o ciclo de infra destruído no passo final para não acumular custo.

> [!TIP]
> Ao longo do lab você vai encontrar blocos `<details><summary>💡 Clique para entender</summary>`. Eles aprofundam o "porquê" do passo sem travar a execução. Se estiver com pressa, **pule**; se quiser absorver de verdade, **abra**.

## Mapa do lab

| # | Parte | O que acontece | Tempo |
|---|-------|---------------|-------|
| 1 | [Provisionar infra com Terraform](#parte-1---provisionar-a-infraestrutura) | Cluster ECS, repositório ECR, task definition, service, security group. | ~10 min |
| 2 | [Build e push da imagem para o ECR](#parte-2---build-e-push-da-imagem) | `docker build`, login no ECR, `docker push`, force-deploy do service. | ~15 min |
| 3 | [Validar e acessar a aplicação](#parte-3---validar-e-acessar-a-aplicação) | Verificar task `RUNNING`, pegar IP público, testar via navegador ou `curl`. | ~10 min |
| 4 | [Limpeza](#parte-4---limpeza) | `terraform destroy` para zerar o custo. | ~5 min |

<details>
<summary><b>💡 O que é ECS + Fargate em 3 parágrafos (abra se nunca viu em aula)</b></summary>
<blockquote>

**ECS (Elastic Container Service)** é o orquestrador de containers gerenciado da AWS. Ele cuida de decidir onde cada container roda, de reiniciá-lo quando falha, de escalar para cima ou para baixo, e de conectar o container na rede (VPC, subnets, security groups). Pense nele como um "Kubernetes simplificado feito pela AWS".

O ECS tem dois modos de execução: **EC2**, em que você é dono das máquinas onde os containers rodam, e **Fargate**, em que a AWS te entrega capacidade de CPU e memória sob demanda e você nunca vê a VM por baixo. Fargate cobra por segundo de uso da task — bom para cargas esporádicas, ruim para cargas 24/7 de alto volume (aí EC2 sai mais barato).

**ECR (Elastic Container Registry)** é o Docker Hub privado da AWS, integrado ao IAM. Toda imagem que sua task do ECS vai rodar precisa estar em um registro acessível. O ECR é a escolha natural porque a `execution_role` da task já tem permissão nativa de puxar dali, sem chave ou senha.

</blockquote>
</details>

## Contexto

A aula cobriu três modelos de execução na AWS: VM crua (EC2), container orquestrado (ECS/EKS) e função (Lambda). Este lab aprofunda o segundo modelo com o sabor que mais aparece em vagas de engenharia hoje: ECS com Fargate. Ao contrário do Lab 03.1 (x86 vs Graviton), aqui você não vai comparar arquiteturas — o foco é entender como as peças do ECS se encaixam e como o ECR fecha o loop do deploy.

O serviço ECS é um *controller*: ele fica observando o estado desejado (`desired_count=1`) e, quando a imagem no ECR aparece pela primeira vez, sobe a task. Se a task cai, ele sobe outra. Esse comportamento de *self-healing* é o que faz com que o Terraform aplique a infra antes da imagem existir: o service simplesmente vai ficar em erro cíclico até o `docker push` completar.

---

## Parte 1 - Provisionar a infraestrutura

### Resultado esperado desta parte

Terraform aplicado sem erro, ECR vazio criado, cluster ECS criado, service ECS criado mas com `runningCount=0` (é esperado — ainda não há imagem).

1. Entre na pasta do Terraform:

```bash
cd /workspaces/fiap-cloud-engineering/03-Compute/02-ECS-Fargate/terraform
```

2. Descubra o bucket de estado do Terraform e substitua o placeholder em `state.tf`:

```bash
export bucket=$(aws s3 ls | awk '/base-config-/ {print $3; exit}')
echo "Bucket detectado: $bucket"
sed -i "s/base-config-SEU_RM/$bucket/g" state.tf
```

Confira que `Bucket detectado:` mostrou um nome válido. Se veio vazio, **pare** — o setup de credenciais da aula não foi executado, volte ao [Preparando Credenciais](../../01-create-codespaces/Inicio-de-aula.md).

<details>
<summary><b>⚠ Se der erro: <code>An error occurred (InvalidAccessKeyId)</code> ou <code>AuthFailure</code></b></summary>
<blockquote>
As credenciais da AWS Academy expiraram (duram 4 horas). Volte ao [Preparando Credenciais](../../01-create-codespaces/Inicio-de-aula.md), puxe credenciais novas e repita o passo 2.
</blockquote>
</details>

3. Inicialize o Terraform (vai baixar providers e configurar o backend S3):

```bash
terraform init
```

4. Aplique o plano:

```bash
terraform apply -auto-approve
```

<details>
<summary><b>💡 Clique para entender — anatomia do Terraform deste lab</b></summary>
<blockquote>

**`data "aws_caller_identity" "current"`** — consulta a conta AWS corrente para montar dinamicamente o ARN da `LabRole` (a role padrão do AWS Academy). Evita hardcoded de account id.

**`aws_ecs_cluster`** — cria o cluster `ecs-fargate-lab-cluster`. No modo Fargate, o cluster é quase só um nome lógico: não há EC2 provisionada.

**`aws_ecr_repository`** — cria o repositório privado `ecs-fargate-lab`. Nasce vazio; quem popula é o `docker push` da Parte 2.

**`aws_ecs_task_definition`** — a "receita" do container:

| Campo | Significado |
|-------|-------------|
| `family` | Nome lógico da task definition (`ecs-fargate-lab-task`). |
| `network_mode = "awsvpc"` | Obrigatório no Fargate — cada task ganha ENI e IP próprios. |
| `requires_compatibilities = ["FARGATE"]` | Declara que a task roda em Fargate, não em EC2. |
| `cpu = "256"` / `memory = "512"` | 0.25 vCPU e 512 MB. É o menor tamanho válido em Fargate. |
| `execution_role_arn` | ARN da `LabRole`, que dá permissão ao ECS de puxar imagem do ECR e escrever logs. |
| `container_definitions` | Bloco JSON com nome, imagem (`:latest`), porta 3000 exposta. |

**`aws_ecs_service`** — o *loop de controle*. Mantém `desired_count=1` task sempre viva. Recria se ela cair. Na criação, escolhe uma subnet pública via `random_shuffle` e atribui IP público.

**Gotcha real:** a task definition aponta para `:latest`. Se você fizer um segundo `docker push :latest` com conteúdo novo, o ECS **não** detecta a mudança sozinho — precisa de um `aws ecs update-service --force-new-deployment` (usado no passo 11 deste lab).

Referência oficial: [Amazon ECS on Fargate — Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html).

</blockquote>
</details>

<!-- PRINT SUGERIDO: img/15.png
     Saída final do `terraform apply` mostrando "Apply complete! Resources: N added". -->
![](img/15.png)

5. Verifique rapidamente que os três recursos nasceram:

```bash
aws ecs describe-clusters --clusters ecs-fargate-lab-cluster \
  --query "clusters[0].{name:clusterName,status:status}"
aws ecr describe-repositories --repository-names ecs-fargate-lab \
  --query "repositories[0].{name:repositoryName,uri:repositoryUri}"
aws ecs describe-services --cluster ecs-fargate-lab-cluster --services ecs-fargate-app-service \
  --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}"
```

Saída esperada do último comando:

```json
{
  "desired": 1,
  "running": 0,
  "pending": 1
}
```

> [!NOTE]
> `running=0` aqui é **esperado e correto**. O ECS já tentou subir a task mas a imagem ainda não existe no ECR — ele vai ficar tentando. No console você pode ver eventos tipo `CannotPullContainerError: image not found`. Não se assuste: isso se resolve sozinho assim que você fizer o push na Parte 2.

<details>
<summary><b>⚠ Se der erro: <code>Error: error creating ECS service: InvalidParameterException</code></b></summary>
<blockquote>
Costuma ser VPC/subnet do lab anterior. Rode `terraform destroy -auto-approve` e depois `terraform apply -auto-approve` de novo. Se persistir, confirme com `aws ec2 describe-vpcs --filters "Name=tag:Name,Values=fiap-lab"` que a VPC `fiap-lab` existe.
</blockquote>
</details>

### Checkpoint

- [x] `terraform apply` retornou `Apply complete!`.
- [x] ECR `ecs-fargate-lab` existe e está vazio.
- [x] ECS service `ecs-fargate-app-service` existe com `desiredCount=1`, `runningCount=0`.

---

## Parte 2 - Build e push da imagem

### Resultado esperado desta parte

Imagem Docker buildada localmente no Codespaces, taggeada com a URI do ECR, pushada com sucesso, e task do ECS transicionando de `PENDING` para `RUNNING`.

6. Entre na pasta do código da aplicação:

```bash
cd /workspaces/fiap-cloud-engineering/03-Compute/02-ECS-Fargate/app
```

7. Faça login no ECR (o comando abaixo descobre a URL do repo e faz o login Docker com token temporário do IAM):

```bash
ECR_REPO_URL=$(aws ecr describe-repositories --repository-name ecs-fargate-lab | jq .repositories[0].repositoryUri -r)
echo "ECR URL: $ECR_REPO_URL"
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REPO_URL
```

Saída esperada: `Login Succeeded`.

<!-- PRINT SUGERIDO: img/1.png
     Terminal com o "Login Succeeded" após o docker login no ECR. -->
![](img/1.png)

<details>
<summary><b>💡 Clique para entender — por que o login é via <code>get-login-password</code></b></summary>
<blockquote>
O ECR não usa usuário/senha fixos. Toda autenticação usa um **token temporário de 12 horas** gerado pelo IAM a partir das suas credenciais AWS. Por isso o comando `aws ecr get-login-password` é pipado para `docker login --password-stdin` — o token vive só no `stdin` e nunca toca o disco.
</blockquote>
</details>

8. Builde a imagem:

```bash
docker build -t ecs-fargate-lab .
```

<!-- PRINT SUGERIDO: img/2.png
     Saída do docker build mostrando os steps e "Successfully tagged ecs-fargate-lab:latest". -->
![](img/2.png)

9. Tag da imagem com a URI do ECR (o Docker por padrão publica em Docker Hub; a tag com o hostname do ECR é o que redireciona o push):

```bash
docker tag ecs-fargate-lab:latest $ECR_REPO_URL:latest
```

10. Faça o push para o ECR:

```bash
docker push $ECR_REPO_URL:latest
```

<!-- PRINT SUGERIDO: img/3.png
     Saída do docker push mostrando os layers sendo enviados e o digest final. -->
![](img/3.png)

<details>
<summary><b>⚠ Se der erro: <code>denied: User is not authorized to perform: ecr:InitiateLayerUpload</code></b></summary>
<blockquote>
O token do ECR expirou (dura 12h) ou você está autenticado em outra conta AWS. Repita o passo 7 para refazer o login e tente o push novamente.
</blockquote>
</details>

11. Force um novo deployment no service para o ECS puxar a imagem recém-pushada imediatamente (sem isso, ele até se recupera sozinho, mas pode demorar até 3 min no ciclo de retry):

```bash
aws ecs update-service \
  --cluster ecs-fargate-lab-cluster \
  --service ecs-fargate-app-service \
  --force-new-deployment \
  --query "service.{status:status,desired:desiredCount,running:runningCount}"
```

12. Confira no console AWS que a imagem está mesmo no ECR. Acesse o [console do ECR](https://us-east-1.console.aws.amazon.com/ecr/private-registry/repositories?region=us-east-1) e clique no repositório `ecs-fargate-lab`.

<!-- PRINT SUGERIDO: img/4.png
     Console ECR mostrando o repositório ecs-fargate-lab na lista. -->
![](img/4.png)

<!-- PRINT SUGERIDO: img/5.png
     Dentro do repositório, a imagem :latest com o digest e o "Pushed at" recente. -->
![](img/5.png)

### Checkpoint

- [x] `docker push` terminou sem erro e exibiu o digest da imagem.
- [x] Console do ECR mostra a imagem `:latest` com timestamp recente.
- [x] `aws ecs describe-services ... --query "services[0].runningCount"` retorna `1` em até 2 minutos.

<details>
<summary><b>⚠ Se der erro: <code>runningCount</code> fica travado em 0 por mais de 3 minutos</b></summary>
<blockquote>
Rode `aws ecs describe-services --cluster ecs-fargate-lab-cluster --services ecs-fargate-app-service --query "services[0].events[0:5]"` e leia os eventos mais recentes. Os erros típicos:

- `CannotPullContainerError: manifest not found` → a tag `:latest` não foi pushada; refaça o passo 10.
- `ResourceInitializationError: unable to pull secrets or registry auth` → a `LabRole` perdeu permissão; recrie o ambiente com `terraform destroy` + `terraform apply`.
- `insufficient capacity` → região sem capacidade Fargate; espere 2 min e rode o `--force-new-deployment` do passo 11 de novo.
</blockquote>
</details>

---

## Parte 3 - Validar e acessar a aplicação

### Resultado esperado desta parte

Task `RUNNING` no ECS, IP público descoberto, endpoint HTTP retornando a mensagem `🚀 Aplicação rodando no ECS com Fargate!`.

13. Acesse o [console do ECS](https://us-east-1.console.aws.amazon.com/ecs/home?region=us-east-1#/clusters) e clique no cluster `ecs-fargate-lab-cluster`.

<!-- PRINT SUGERIDO: img/6.png
     Lista de clusters do ECS com o ecs-fargate-lab-cluster destacado. -->
![](img/6.png)

14. Na aba `Serviços`, clique em `ecs-fargate-app-service` para ver o detalhe.

<!-- PRINT SUGERIDO: img/7.png
     Aba de Serviços do cluster, com ecs-fargate-app-service listado. -->
![](img/7.png)

<!-- PRINT SUGERIDO: img/8.png
     Detalhe do serviço mostrando runningCount=1 e status ACTIVE. -->
![](img/8.png)

15. Abra a aba `Tarefas` do serviço.

<!-- PRINT SUGERIDO: img/9.png
     Aba Tarefas do serviço com uma task em status RUNNING. -->
![](img/9.png)

16. Clique na tarefa em execução para ver o detalhe.

<!-- PRINT SUGERIDO: img/10.png
     Detalhe da task mostrando task ID, status RUNNING, cluster, task definition. -->
![](img/10.png)

17. Role até `Configuração de rede` (ou `Associações de rede`, depende da interface atual) e localize o IP público.

<!-- PRINT SUGERIDO: img/11.png
     Bloco de rede mostrando ENI, subnet, IP público e privado. -->
![](img/11.png)

18. Clique em `endereço aberto` (ou copie o IP manualmente) para abrir no navegador. Adicione `:3000` ao final se não estiver incluso:

<!-- PRINT SUGERIDO: img/12.png
     Botão/link "endereço aberto" com o IP da task. -->
![](img/12.png)

19. Se tudo deu certo, você verá a mensagem da aplicação:

<!-- PRINT SUGERIDO: img/13.png
     Navegador mostrando "🚀 Aplicação rodando no ECS com Fargate!" na URL http://<IP>:3000. -->
![](img/13.png)

> [!TIP]
> Se estiver na **rede da FIAP** ou em qualquer rede corporativa que bloqueie portas não padrão, o navegador pode não abrir. **Não espere** — vá direto para o passo 20 e teste via `curl` no terminal do Codespaces (o Codespaces roda na nuvem, ignora firewall local).

20. Teste via `curl` no terminal do Codespaces (substitua `<IP_DO_FARGATE>` pelo IP que você copiou do console):

```bash
curl http://<IP_DO_FARGATE>:3000
```

Saída esperada:

```
🚀 Aplicação rodando no ECS com Fargate!
```

<!-- PRINT SUGERIDO: img/14.png
     Terminal do Codespaces mostrando o curl e a resposta da aplicação. -->
![](img/14.png)

<details>
<summary><b>⚠ Se der erro: <code>curl: (28) Connection timed out</code></b></summary>
<blockquote>
O IP está certo mas o tráfego não chega. Causas comuns:

- A task já foi substituída e o IP antigo não existe mais — volte ao passo 17 e pegue o IP atual.
- Security group não liberou a porta 3000 — confira em `aws ec2 describe-security-groups --filters "Name=group-name,Values=sec-fargate" --query "SecurityGroups[0].IpPermissions"`.
- A subnet escolhida não é pública (sem route para IGW) — raro neste lab porque filtramos por `tag:Tier=Public`, mas possível se a VPC foi modificada.
</blockquote>
</details>

### Checkpoint

- [x] Task em `RUNNING`.
- [x] IP público visível no console.
- [x] `curl http://<IP>:3000` retornou a mensagem da aplicação.

---

## Parte 4 - Limpeza

### Resultado esperado desta parte

Todos os recursos destruídos, conta AWS sem cobrança residual de Fargate ou ECR.

> [!CAUTION]
> **Esse passo não é opcional.** Fargate cobra por segundo de task rodando. ECR cobra armazenamento. Uma task esquecida ligada custa alguns dólares por dia — em 2 semanas você esgota a cota do Learner Lab e perde acesso à aula. Sempre destrua no fim.

21. Volte para a pasta do Terraform e destrua tudo:

```bash
cd /workspaces/fiap-cloud-engineering/03-Compute/02-ECS-Fargate/terraform
terraform destroy -auto-approve
```

22. Confirme que o cluster sumiu:

```bash
aws ecs describe-clusters --clusters ecs-fargate-lab-cluster \
  --query "clusters[0].status"
```

Saída esperada: `"INACTIVE"` ou `null` (cluster não encontrado).

### Checkpoint

- [x] `terraform destroy` terminou com `Destroy complete!`.
- [x] Cluster `INACTIVE` ou ausente.
- [x] ECR `ecs-fargate-lab` não aparece mais em `aws ecr describe-repositories`.

---

## Conclusão

Você provisionou do zero um ambiente de orquestração de containers na AWS: um cluster ECS em modo Fargate, um registro privado no ECR, uma task definition declarando CPU, memória e porta, e um service mantendo a task viva. Publicou uma imagem Docker construída localmente e observou o loop de controle do ECS puxando a imagem e subindo a task automaticamente. Validou o endpoint público e, por último, destruiu todo o ambiente.

Os dois aprendizados centrais para levar:

1. **Infra nasce antes da imagem.** O service ECS tolera a ausência da imagem no ECR por design; ele fica em erro cíclico e se autorrecupera quando a imagem aparece. Isso permite separar o pipeline de infra do pipeline de aplicação.
2. **Fargate esconde a VM mas não a VPC.** Você ainda define subnet, security group e IP público. A diferença é que não existe uma EC2 rodando na sua conta — a AWS multiplexa as tasks em capacidade compartilhada.

## Próximo passo

Este é o último laboratório do módulo de Compute. Com EFS (storage), x86 vs Graviton e ECS+Fargate na bagagem, você já tem as peças de storage e compute para montar arquiteturas completas combinando storage, compute e networking — com ECS Fargate como peça de compute em várias delas.

---

<details>
<summary><b>💡 Glossário rápido</b></summary>
<blockquote>

| Termo | O que é |
|-------|---------|
| ECS | Elastic Container Service — orquestrador de containers gerenciado da AWS. |
| Fargate | Modo de execução do ECS sem servidor; você paga por segundo de CPU/RAM da task. |
| ECR | Elastic Container Registry — registro privado de imagens Docker integrado ao IAM. |
| Task definition | "Receita" que descreve imagem, CPU, RAM, portas e role de execução de um container. |
| Task | Instância em execução de uma task definition. |
| Service | Controller que mantém N tasks rodando; reinicia quando uma cai. |
| `awsvpc` | Network mode em que cada task recebe sua própria ENI e IP na VPC. |
| ENI | Elastic Network Interface — placa de rede virtual anexada à task. |
| `LabRole` | Role IAM pré-criada pela AWS Academy com permissões para os labs. |
| `:latest` | Tag Docker móvel — sempre aponta para o último push com esse label. |
| `--force-new-deployment` | Flag do ECS que força o service a substituir a task mesmo sem mudança na task definition. |

</blockquote>
</details>

<details>
<summary><b>💡 Como pedir ajuda se travou</b></summary>
<blockquote>

**Antes de abrir issue ou chamar o professor, colete:**

1. Em qual passo (número) travou.
2. A mensagem de erro **literal** (copie e cole, não resuma).
3. O que `aws sts get-caller-identity` retorna agora.
4. Se já tentou `terraform destroy` + `terraform apply` novamente.

**Canais, em ordem:**

1. [Issues deste repositório](https://github.com/vamperst/fiap-cloud-engineering/issues) — preferido, cria histórico pesquisável para os próximos alunos.
2. Email do professor com os 4 itens acima.
3. Na sala de aula, durante o laboratório.

</blockquote>
</details>
