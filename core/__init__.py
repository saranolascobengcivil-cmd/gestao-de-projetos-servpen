# Pacote core — módulos compartilhados entre as views (pages) do app.
#
# Estrutura:
#   helpers      — UI helpers stateless (tema, badges, tags, headers, etc.)
#   data         — _load_df_* cacheados + _invalidar_dados
#   auth_ui      — tela_login, _dialog_meu_perfil, helpers de avatar
#   mencoes      — popover @, extração e processamento de menções no Diário
#   chat_utils   — _render_chat_messages (fragmento 2s), _chat_toast_html
#   notif        — _global_notif (fragmento 10s, montado na sidebar)
#
# Cada view (views/*.py) importa daqui o que precisa. Não há estado
# global compartilhado além do st.session_state e do cache do Streamlit.
