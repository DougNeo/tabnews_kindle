# TabNews para KOReader

[![Testes](https://github.com/DougNeo/tabnews_kindle/actions/workflows/test.yml/badge.svg)](https://github.com/DougNeo/tabnews_kindle/actions/workflows/test.yml)

Plugin para ler o [TabNews](https://www.tabnews.com.br) no KOReader (Kindle, Kobo, PocketBook…), com leitura offline.

## Recursos

- Listas de posts **Relevantes** e **Recentes**, com tabcoins, comentários e tempo de leitura
- **Edição do dia**: os 10 posts mais relevantes num único documento com índice
- **Busca** na web (DuckDuckGo) + índice local de títulos + texto completo dos posts salvos (funciona offline)
- **Imagens** baixadas junto com o post
- **Autores favoritos** e **categorias escondidas** (ex.: esconder todos os `Pitch:`) — segure o dedo num post
- **Tabcoins**: dê +1/−1 no post aberto (login com a sua conta; só o token de sessão é guardado)
- **Atualizar comentários** do post aberto e contador `(+N)` de comentários novos na lista
- **Sincronização automática** ao conectar no Wi-Fi (opcional), que pode ser cancelada com um toque e desligar o Wi-Fi no final para economizar bateria
- **Atualização automática do plugin:** ele avisa quando sai versão nova e se atualiza pelo Wi-Fi
- **Markdown completo para leitura:** tabelas, listas aninhadas, listas de tarefas, blocos de código, links e as tags HTML mais usadas nos posts
- **Limpeza** de posts sem uso há 30 dias

## Instalação

Baixe o `tabnews.koplugin.zip` da [última release](https://github.com/DougNeo/tabnews_kindle/releases/latest), descompacte e copie a pasta `tabnews.koplugin` para `koreader/plugins/`. Depois reinicie o KOReader.
O menu fica em **Ferramentas → TabNews**.

Via SSH, por exemplo pelo Termux no celular (com o servidor SSH do KOReader ativo):

```bash
curl -L -o tabnews.koplugin.zip https://github.com/DougNeo/tabnews_kindle/releases/latest/download/tabnews.koplugin.zip
unzip -o tabnews.koplugin.zip
tar -cf - tabnews.koplugin | ssh -p 2222 root@IP_DO_KINDLE "tar -xf - -C /mnt/us/koreader/plugins"
```

## Atualizando

Depois de instalado uma vez, o plugin se atualiza sozinho: em **Ferramentas → TabNews → Configurações → Verificar atualização**, ou automaticamente durante a sincronização.

## Arquivos

- Posts salvos: `koreader/tabnews/`
- Configurações: `koreader/settings/tabnews.lua`
- Índice de busca: `koreader/settings/tabnews_index.lua`

## Desenvolvimento

Os testes rodam sem KOReader e sem rede, só com LuaJIT:

```bash
luajit tests/run.lua
```

Para publicar uma versão nova, atualize `VERSION` em `tabnews.koplugin/main.lua` e envie uma tag com o mesmo número:

```bash
git tag v1.0 && git push origin main --tags
```

O GitHub Actions roda os testes, confere a versão, gera o `tabnews.koplugin.zip` e publica a release. A partir daí, os Kindles com o plugin instalado recebem a atualização.

Usa a API pública do TabNews. Projeto não oficial.

Licença: MIT.
