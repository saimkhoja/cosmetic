// The app itself. main.tsx loads this only after it knows which client's database to use (lib/tenant.ts),
// because lib/supabase.ts builds its client the moment it is first imported.
import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import App from './App';
import { AuthProvider } from './auth/AuthProvider';
import { Toasts } from './components/ui';

const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 30_000, retry: 1, refetchOnWindowFocus: true } } });

export function start(root: ReactDOM.Root) {
  root.render(
    <React.StrictMode>
      <QueryClientProvider client={qc}>
        <BrowserRouter>
          <Toasts><AuthProvider><App /></AuthProvider></Toasts>
        </BrowserRouter>
      </QueryClientProvider>
    </React.StrictMode>,
  );
}
