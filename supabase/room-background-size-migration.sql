-- Raise the shared room-assets bucket upload cap to 10 MB.
update storage.buckets
set file_size_limit = 10485760
where id = 'room-assets';
