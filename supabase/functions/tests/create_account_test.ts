import { assertEquals } from 'jsr:@std/assert@1';
import { handler } from '../create-account/index.ts';
import { jsonResponse, stubFetch } from './helpers.ts';

const body = {
   account: { email: 'new@example.test', password: 'password-123' },
   company: { display_name: 'New Company', email: 'company@example.test' }
};

const post = () =>
   new Request('http://localhost/create-account', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
   });

/** Answers open_signup_enabled with `open`; records every other call. */
const backend = (open: boolean) => {
   const other: string[] = [];
   const restore = stubFetch((url) => {
      if (url.pathname === '/rest/v1/rpc/open_signup_enabled') return jsonResponse(open);
      other.push(url.pathname);
      return jsonResponse({}, 500);
   });
   return { other, restore };
};

Deno.test('POST is refused with signup_closed when the setting is off', async () => {
   const { other, restore } = backend(false);
   try {
      const response = await handler(post());
      assertEquals(response.status, 403);
      assertEquals((await response.json()).code, 'signup_closed');
      assertEquals(
         other.filter((path) => path.startsWith('/auth/v1/admin/users')),
         [],
         'no user is created'
      );
      assertEquals(other, [], 'nothing else is called');
   } finally {
      restore();
   }
});

Deno.test('GET reports the setting', async () => {
   for (const open of [false, true]) {
      const { restore } = backend(open);
      try {
         const response = await handler(new Request('http://localhost/create-account'));
         assertEquals(response.status, 200);
         assertEquals(await response.json(), { open });
      } finally {
         restore();
      }
   }
});
