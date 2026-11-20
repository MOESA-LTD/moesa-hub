CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Task marketing roles (076): a task template and a project task may name a marketing or content
-- role; an unknown role is still refused.
BEGIN;

SELECT plan(7);

SELECT lives_ok(
   format($$ INSERT INTO public.task_template (phase, position, display_name, role, blocks_gate)
             VALUES ('PL7', %s, 'test', %L, FALSE) $$, 900 + n, role),
   format('a task template may name the %s role', role)
)
FROM unnest(ARRAY['packaging_designer', 'photo_video', 'seo_copywriter', 'listing_team', 'content_listing'])
     WITH ORDINALITY AS r(role, n);

SELECT throws_ok(
   $$ INSERT INTO public.task_template (phase, position, display_name, role, blocks_gate)
      VALUES ('PL7', 999, 'test', 'astrologer', FALSE) $$,
   '23514', NULL,
   'an unknown task role is refused'
);

SELECT is(
   (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'project_task_role_check'),
   (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'task_template_role_check'),
   'a project task takes the same roles as its template'
);

SELECT * FROM finish();
ROLLBACK;
