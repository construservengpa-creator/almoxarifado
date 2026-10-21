-- Remove do banco a rotina "Zerar todo o estoque" (zona de risco), que saiu do sistema.
-- Sem esta função, ninguém consegue apagar a base inteira de uma vez, nem chamando a API direto.
drop function if exists public.zerar_estoque_admin();
