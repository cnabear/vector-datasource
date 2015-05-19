-- This file contains functions (see `mz_SplitIntoTiles()`) for splitting a
-- table of polygons into uniform tiles.

-- A function that creates a table containing a grid of cells, taken from here:
-- http://gis.stackexchange.com/questions/16374/how-to-create-a-regular-polygon-grid-in-postgis
create or replace function mz_CreateGrid(
	nrow integer,
	ncol integer,
	xsize float8,
	ysize float8,
	x0 float8 default 0,
	y0 float8 default 0,
	out "row" integer,
	out col integer,
	out the_geom geometry
)
returns setof record as
$$
	select
		rowInd + 1 as row,
		colInd + 1 as col,
		st_Translate(cell, colInd * $3 + $5, rowInd * $4 + $6) as the_geom
	from
		generate_series(0, $1 - 1) as rowInd,
		generate_series(0, $2 - 1) as colInd,
		(select ('POLYGON((0 0, 0 ' || $4 || ', ' || $3 || ' ' || $4 || ', ' || $3 || ' 0,0 0))')::geometry as cell) as foo;
$$ language sql immutable strict;

-- Split the polygons in a table called `table_name` into uniformly sized tiles
-- in a table called `${table_name}_tiles`.
create or replace function mz_SplitIntoTiles(
	table_name text,
	tile_size_meters integer,
	geom_column_name text default 'the_geom'
)
returns void as
$$
	declare
		grid_table_name text := table_name || '_grid';
		table_bbox box2d;
		num_tiles_x integer;
		num_tiles_y integer;
	begin
		execute format('select st_extent(%s) from %s', geom_column_name, table_name) into table_bbox;
		num_tiles_x = ceiling(
			(st_xmax(table_bbox) - st_xmin(table_bbox)) / (tile_size_meters :: float)
		);
		num_tiles_y = ceiling(
			(st_ymax(table_bbox) - st_ymin(table_bbox)) / (tile_size_meters :: float)
		);

		-- Create a table containing a grid with cells of length/width
		-- `tile_size_meters`, covering the entire extent of `table_name`.
		execute format(
			'create table %s as
			select *
			from MZ_CreateGrid(%s, %s, %s, %s, %s, %s);',
			grid_table_name, num_tiles_x, num_tiles_y,
			tile_size_meters, tile_size_meters,
			st_xmin(table_bbox), st_ymin(table_bbox)
		);
		perform UpdateGeometrySRID(grid_table_name, 'the_geom', 900913);
		execute format('create index %s_index on %1$s using gist(the_geom)', grid_table_name);

		-- Intersect the gridded cells with the polygons in `table_name`,
		-- storing the now-tiled polygons in `${table_name}_tiles`.
		execute format(
			'create table %1$s_tiles as
			select
				row::text || ''-'' || col::text as gid,
				st_intersection(%1$s.%3$s, %2$s.the_geom) as geom
			from %1$s
			join %2$s
			on (
				st_isvalid(%1$s.%3$s) and
				st_intersects(%1$s.%3$s, %2$s.the_geom)
			);',
			table_name, grid_table_name, geom_column_name
		);
		execute 'drop table ' || grid_table_name;
	end
$$ language plpgsql;
