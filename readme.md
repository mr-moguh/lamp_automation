# Simple LAMP Installer - Guia de Utilização (v13)

> **Versão:** 13 (Final)
> **Sistema Alvo:** CentOS Stream 10 / RHEL
> **Objetivo:** Automatização de Servidores Web, Banco de Dados e Segurança.

---

## Visão Geral

Este script Bash automatiza a instalação e configuração de uma stack **LAMP** (Linux, Apache, MariaDB, PHP). Ele foi desenhado para ser **modular**, permitindo duas formas de uso:
1.  **Full Installation:** Um assistente passo a passo que configura o servidor do zero até o site estar no ar.
2.  **Menu Individual:** Ferramentas para instalar ou configurar serviços específicos separadamente (ex: apenas configurar o Banco de Dados ou apenas renovar o SSL).

### Funcionalidades Principais
* **Smart Deploy:** Clona um site do GitHub, detecta configurações e importa o Banco de Dados automaticamente.
* **Segurança:** Configura Firewall, SELinux, Fail2ban e altera porta SSH.
* **HTTPS:** Integração automática com Let's Encrypt (Certbot).
* **Backups:** Configura rotinas diárias de backup.

---

## Como Iniciar

1.  **Baixe o script** para o seu servidor (via `git clone` ou `scp`).
2.  **Dê permissão de execução**:
    ```bash
    chmod +x zproject_lamp_dario-v3.sh
    ```
3.  **Execute como root**:
    ```bash
    sudo ./zproject_lamp_dario-v3.sh
    ```

---

## Guia Passo a Passo das Interações

Ao executar o script, você verá o **Menu Principal**. Abaixo explicamos o que preencher em cada cenário.

### Opção 1: Full Installation (Recomendado)
*Escolha esta opção para configurar um servidor "limpo" do zero.*

#### A. Configuração de Rede
O script perguntará sobre a interface de rede.
* **Interface name:** Digite o nome da sua placa (ex: `ens33`, `eth0`). Use o comando `ip a` em outra aba se não souber.
* **Static IP:** O IP que você deseja fixar (ex: `192.168.1.200/24`).
* **Gateway:** O IP do seu roteador (ex: `192.168.1.1`).
* **DNS:** Servidor DNS (ex: `1.1.1.1` ou `8.8.8.8`).

#### B. Segurança SSH
* **SSH Port:** Escolha uma porta diferente da 22 para evitar ataques (ex: `2222`).
* **Disable root login?** `yes` (Recomendado por segurança).
* **Disable password auth?** `yes` (Se você já configurou chaves SSH) ou `no` (Se ainda usa senha).
* **Allowed users:** Digite os nomes dos usuários Linux que podem acessar (ex: `admin user1`).

#### C. Domínio e Email
* **Domain name:** O endereço do seu site (ex: `meusite.duckdns.org`). *Não coloque http://*.
* **Email for SSL:** Seu email para receber avisos do Let's Encrypt.

#### D. DuckDNS (Opcional)
Se você usa IP Dinâmico:
* **DuckDNS subdomain:** Apenas o nome (ex: `meusite`).
* **DuckDNS token:** O token copiado da sua conta DuckDNS.
* *Se não usar DuckDNS, deixe em branco e pressione Enter.*

#### E. Conteúdo do Site (GitHub)
* **GitHub Repository URL:** O link HTTPS do seu projeto (ex: `https://github.com/usuario/repo.git`).
    * *Se deixar em branco, o script criará uma página de teste PHP padrão.*

#### F. Configuração do Banco de Dados (Wizard Interativo)
Esta é a parte mais importante para sites dinâmicos.

1.  **Does your website require a database?**
    * Digite `yes` se for WordPress, Laravel, ou sistema com login/produtos.
    * Digite `no` se for apenas HTML/CSS estático.

2.  **Se respondeu YES:**
    * **DB Name:** Invente um nome para o banco (ex: `loja_db`).
    * **DB User:** Invente um usuário para o site usar (ex: `loja_user`).
    * **DB Password:** Invente uma senha forte.
    * **Config File Path:** O script tentará detectar automaticamente. Se ele não achar, digite o caminho onde seu site espera a conexão (ex: `config/db.php`).

> **Nota:** O script irá **automaticamente** importar qualquer arquivo `.sql` que estiver no seu repositório GitHub para o banco que você acabou de criar.

#### G. Finalização SSL
* **Port forwarding configured?**
    * `yes`: Se você já abriu as portas 80/443 no roteador. O script vai gerar o certificado agora.
    * `no`: O script pulará esta etapa (você pode fazer depois pela opção 15 ou 23).

---

### Módulos Individuais (Opções 3 a 23)
*Use estas opções se quiser realizar apenas uma tarefa específica sem rodar a instalação toda.*

#### 9) Deploy site from GitHub
Baixa a versão mais recente do seu site e ajusta as permissões de pasta (`chown`/`chmod`) e contexto do SELinux.
* **Interação:** Pede apenas a URL do repositório.

#### 10) Setup App Database (Interactive)
Configura o banco de dados para um site já baixado. **Ideal para usar logo após a opção 9.**
* Usa a mesma lógica inteligente da Instalação Completa.
* Procura arquivos `.sql` na pasta do site e importa automaticamente.
* Cria o arquivo de conexão PHP com as credenciais novas.

#### 16) Harden SSH
Altera as configurações de segurança do SSH.
* Útil se você manteve a porta 22 na instalação e decidiu mudar depois.
* Atualiza automaticamente o Firewall e o SELinux para a nova porta.

#### 23) Retry SSL certificate
Tenta gerar o certificado HTTPS novamente.
* Use esta opção se a instalação falhou anteriormente ou se você acabou de configurar o encaminhamento de portas no roteador.

---

## Estrutura de Pastas Criada

O script organiza o servidor da seguinte forma:

| Caminho | Descrição |
| :--- | :--- |
| `/var/www/html` | **Raiz do Site.** Onde os arquivos do GitHub são salvos. |
| `/etc/httpd/conf.d/` | **Configurações do Apache.** Onde fica o VirtualHost do seu domínio. |
| `/opt/duckdns/` | **DuckDNS.** Contém o script de atualização de IP. |
| `/backups/` | **Backups.** Onde os arquivos `.tar.gz` e `.sql` diários são salvos. |
| `/usr/local/bin/` | **Scripts do Sistema.** Scripts auxiliares de manutenção. |

## Resolução de Problemas Comuns

**1. O site conecta, mas diz "Table not found"**
* Isso significa que o arquivo `.sql` no seu GitHub tinha um comando `USE outro_nome_de_banco;`.
* **Solução:** Remova a linha `CREATE DATABASE` ou `USE` do seu arquivo SQL no GitHub e rode a **Opção 10** novamente.

**2. Erro de Permissão (403 Forbidden)**
* Geralmente causado pelo SELinux.
* **Solução:** Rode a **Opção 7 (Configure SELinux)** no menu.

**3. SSL falha ao gerar**
* Verifique se as portas 80 e 443 estão abertas no seu roteador e apontando para o IP do servidor.
* Verifique se o seu domínio DuckDNS está apontando para o seu IP Público atual.