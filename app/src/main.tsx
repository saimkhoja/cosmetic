import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { registerSW } from 'virtual:pwa-register';
import './styles.css';
import App from './App';
import { AuthProvider } from './auth/AuthProvider';
import { Toasts } from './components/ui';

registerSW({ immediate: true });
const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 30_000, retry: 1, refetchOnWindowFocus: true } } });

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={qc}>
      <BrowserRouter>
        <Toasts><AuthProvider><App /></AuthProvider></Toasts>
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
);
