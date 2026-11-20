-- 076: marketing and content roles for project tasks. The task roles of 021 (coordinator,
-- supply_qc, compliance, content_listing, logistics, finance, management) had no place for the
-- people a private-label launch hands work to: the 2026-11-20 UI demo (elastic group, projects
-- MKT-2026-044..046) saved its packaging, photo, copy and upload tasks without a role.
--
--   packaging_designer  packaging and label artwork
--   photo_video         product photos, renders, infographics and video
--   seo_copywriter      listing copy and keyword research
--   listing_team        marketplace uploads and listing checks
--
-- content_listing stays: the gates' derived roles (022, 058) and the task templates use it.

ALTER TABLE public.task_template DROP CONSTRAINT IF EXISTS task_template_role_check;
ALTER TABLE public.task_template ADD CONSTRAINT task_template_role_check CHECK (
   role IN ('coordinator', 'supply_qc', 'compliance', 'content_listing', 'logistics', 'finance',
            'management', 'packaging_designer', 'photo_video', 'seo_copywriter', 'listing_team')
);

ALTER TABLE public.project_task DROP CONSTRAINT IF EXISTS project_task_role_check;
ALTER TABLE public.project_task ADD CONSTRAINT project_task_role_check CHECK (
   role IN ('coordinator', 'supply_qc', 'compliance', 'content_listing', 'logistics', 'finance',
            'management', 'packaging_designer', 'photo_video', 'seo_copywriter', 'listing_team')
);
