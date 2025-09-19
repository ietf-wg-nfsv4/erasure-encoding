---
title: Erasure Coding of Files in NFSv4.2
abbrev: Erasure Coding
docname: draft-haynes-nfsv4-erasure-encoding
category: std
date: {DATE}
consensus: true
ipr: trust200902
area: General
workgroup: Network File System Version 4
keyword: Internet-Draft

stand_alone: yes
pi: [toc, sortrefs, symrefs, docmapping]

author:
 -
    ins: T. Haynes
    name: Thomas Haynes
    organization: Hammerspace
    email: loghyr@gmail.com

normative:
  RFC2119:
  RFC4506:
  RFC7530:
  RFC7862:
  RFC7863:
  RFC8174:
  RFC8178:
  RFC8435:
  RFC8881:
  I-D.haynes-nfsv4-flexfiles-v2:

informative:
  Plank97:
  RFC1813:

--- abstract

Parallel NFS (pNFS) allows a separation between the metadata (onto a
metadata server) and data (onto a storage device) for a file.  The
Flexible File Version 2 Layout Type is defined in this document as an
extension to pNFS that allows the use of storage devices that require
only a limited degree of interaction with the metadata server and use
already-existing protocols.  Data replication is also added to
provide integrity.

--- note_Note_to_Readers

Discussion of this draft takes place
on the NFSv4 working group mailing list (nfsv4@ietf.org),
which is archived at
[](https://mailarchive.ietf.org/arch/search/?email_list=nfsv4). Source
code and issues list for this draft can be found at
[](https://github.com/ietf-wg-nfsv4/uncacheable).

Working Group information can be found at [](https://github.com/ietf-wg-nfsv4).

This draft is currently a work in progress.  It needs to be
determined if we want to copy v1 text to v2 or if we want just a diff
of the new content.  For right now, we are copying the v1 text and
adding the new v1 text.  Also, expect sections to move as we push the
emphasis from flex files to protection types.

_As a WIP, the XDR extraction may not yet work._

This draft starts sparse and will be filled in as details are ironed
out.  In the first draft, we simply explain the semantics changes.
As these are accepted by the knowledgeable reviewers, we will flesh
out the operation description sections to include sub-sections more
akin to 18.32.3 and 18.32.4 of {{RFC8881}}.

# Introduction

In Parallel NFS (pNFS) (see Section 12 of {{RFC8881}}), the metadata
server returns layout type structures that describe where file data
is located.  There are different layout types for different storage
and methods of arranging data on storage devices.  {{RFC8435}}
defined the Flexible File Version 1 Layout Type used with file-based
data servers that are accessed using the NFS protocols: NFSv3
{{RFC1813}}, NFSv4.0 {{RFC7530}}, NFSv4.1 {{RFC8881}}, and NFSv4.2
{{RFC7862}}.

The Client Side Mirroring (see Section 8 of {{RFC8435}}), introduced
with the first version of the Flexible File Layout Type, provides for
replication of data but does not provide for integrity of data.  In
the event of an error, an user would be able to repair the file by
silvering the mirror contents.  I.e., they would pick one of the
mirror instances and replicate it to the other instance locations.

However, lacking integrity checks, silent corruptions are not able to
be detected and the choice of what constitutes the good copy is
difficult.  This document updates the Flexible File Layout Type to
version 2 by providing data integrity for erasure coding.  Data
blocks are transformed into a header and a chunk.  It introduces a
new operation ROLLBACK_OPEN that allow the client to maintain
rollbacks to the data file by creating a per client file to store
chunk modifications.  The client writes chunks to the client file and
then atomically exchanges the chunks in the client file with those in
the data file.  In case of write holes, it can rollback the chunks.
It can remove the client file with ROLLBACK_CLOSE.  Both
ROLLBACK_OPEN and ROLLBACK_LIST can be used by the client or metadata
server to recover after a client restart or a client which has
permanently gone away.

Using the process detailed in {{RFC8178}}, the revisions in this
document become an extension of NFSv4.2 {{RFC7862}}.  They are built on
top of the external data representation (XDR) {{RFC4506}} generated
from both {{RFC7863}} and {{I-D.haynes-nfsv4-flexfiles-v2}}.

##  Definitions

chunk:  

:  One of the resulting chunks to be exchanged with a data server after
a transformation has been applied to a data block.  The resulting chunk
may be a different size than the data block.

Client Side Mirroring:  

:  A file based replication method where copies are maintained in parallel.

data block:  

:  A block of data in the client's cache for a file.

data file:  

:  The data portion of the file, stored on the data server.

Erasure Coding:  

:  A data protection scheme where a block of data is replicated into
fragments and additional redundant fragments are added to achieve parity.
The new chunks are stored in different locations.

Client Side Erasure Coding:  

:  A file based integrity method where copies are maintained in parallel.

integrity of data:  

:  Data integrity refers to the accuracy, consistency, and reliability of
data throughout its life cycle.

metadata file:  

:  The metadata portion of the file, stored on the metadata server.

client file:  

:  A temporary file established on the data server by the client to allow
chunks to be swapped with the orginal file.

replication of data:  

:  Data replication is making and storing multiple copies of data in
different locations.

write hole:  

:  A write hole is a data corruption scenario where either two clients
are trying to write to the same chunk or one client is overwriting an
existing chunk of data.

# Flexible File Version 2 Layout Type

In order to introduce erasure coding to pNFS, a new layout type of
LAYOUT4_FLEX_FILES_V2 needs to be defined.  While we could define a
new layout type per erasure coding type, there exist use cases where
multiple erasure coding types exist in the same layout.

The original layouttype4 introduced in {{RFC8881}} is modified to as in
{{fig-orig-layout}}.

~~~ xdr
    enum layouttype4 {
        LAYOUT4_NFSV4_1_FILES   = 1,
        LAYOUT4_OSD2_OBJECTS    = 2,
        LAYOUT4_BLOCK_VOLUME    = 3,
        LAYOUT4_FLEX_FILES      = 4,
        LAYOUT4_FLEX_FILES_V2   = 5
    };

    struct layout_content4 {
        layouttype4             loc_type;
        opaque                  loc_body<>;
    };

    struct layout4 {
        offset4                 lo_offset;
        length4                 lo_length;
        layoutiomode4           lo_iomode;
        layout_content4         lo_content;
    };
~~~
{: #fig-orig-layout title="The original layout type"}

This document defines structures associated with the layouttype4
value LAYOUT4_FLEX_FILES_V2.  {{RFC8881}} specifies the loc_body
structure as an XDR type 'opaque'.  The opaque layout is
uninterpreted by the generic pNFS client layers but is interpreted by
the Flexible File Version 2 Layout Type implementation.  This section
defines the structure of this otherwise opaque value, ffv2_layout4.

## ffv2_coding_type4

~~~ xdr
   /// enum ffv2_coding_type4 {
   ///     FFV2_CODING_MIRRORED       = 0x1;
   /// };
~~~
{: #fig-ffv2_coding_type4 title="The coding type"}

The ffv2_coding_type4 (see {{fig-ffv2_coding_type4}}) encompasses a new IANA registry
for 'Flex Files V2 Erasure Coding Type Registry' (see Section 13.3 of
{{I-D.haynes-nfsv4-flexfiles-v2}})).  I.e., instead of defining a new
Layout Type for each Erasure Coding, we define a new Erasure Coding Type.
Except for FFV2_CODING_MIRRORED, each of the types is expected to employ
the new operations in this document.

FFV2_CODING_MIRRORED offers replication of data and not integrity of
data.  As such, it does not need operations like CHUNK_WRITE (see
Section 9.5).

## To be done later

~~~ xdr
   /// const FFV2_FLAGS_NO_LAYOUTCOMMIT   = 0x00000001;
   /// const FFV2_FLAGS_NO_IO_THRU_MDS    = 0x00000002;
   /// const FFV2_FLAGS_NO_READ_IO        = 0x00000004;
   /// const FFV2_FLAGS_WRITE_ONE_MIRROR  = 0x00000008;
   /// const FFV2_FLAGS_ONLY_ONE_WRITER   = 0x00000010;
   /// typedef uint32_t ffv2_flags4;
~~~
{: #fig-ffv2_flags4 title="The ffv2_flags4" }

The ff2_flags4 in {{fig-ffv2_flags4}}  is a bitmap that allows the metadata
server to inform the client of particular conditions that may result
from more or less tight coupling of the storage devices.

FFV2_FLAGS_NO_LAYOUTCOMMIT:

:  can be set to indicate that the client is not required to send
LAYOUTCOMMIT to the metadata server.

FFV2_FLAGS_NO_IO_THRU_MDS:

:  can be set to indicate that the client should not send I/O operations
to the metadata server.  That is, even if the client could determine
that there was a network disconnect to a storage device, the client
should not try to proxy the I/O through the metadata server.

FFV2_FLAGS_NO_READ_IO:

:  can be set to indicate that the client should not send READ requests
with the layouts of iomode LAYOUTIOMODE4_RW.  Instead, it should request
a layout of iomode LAYOUTIOMODE4_READ from the metadata server.

FFV2_FLAGS_WRITE_ONE_MIRROR:

:  can be set to indicate that the client only needs to update one of
the mirrors (see Section 2.2).

FFV2_FLAGS_ONLY_ONE_WRITER:

:  can be set to indicate that the client only needs to use
CHUNK_WRITE_SWAP to update the chunks in the data file.  I.e., keep the
ability to rollback in case of a write hole caused by overwriting.
If this flag is not set, then the client MUST write chunks with
CHUNK_WRITE_SWAP_GUARD in order to prevent collision across the data
servers.

## ffv2_file_info4

~~~ xdr
   /// struct ffv2_file_info4 {
   ///     stateid4                fffi_stateid;
   ///     nfs_fh4                 fffi_fh_vers;
   /// };
~~~
{: #fig-ffv2_file_info4 title="The ffv2_file_info4" }

The ffv2_file_info4 is a new structure to help with the stateid issue
discussed in Section 5.1 of {{RFC8435}}.  I.e., in version 1 of the
Flexible File Layout Type, there was the singleton ffds_stateid
combined with the ffds_fh_vers array.  I.e., each NFSv4 version has
its own stateid.  In {{fig-ffv2_file_info4}}, each NFSv4 filehandle has a one-to-one
correspondence to a stateid.

## ffv2_ds_flags4

~~~ xdr
   /// const FFV2_DS_FLAGS_ACTIVE        = 0x00000001;
   /// const FFV2_DS_FLAGS_SPARE         = 0x00000002;
   /// const FFV2_DS_FLAGS_PARITY        = 0x00000004;
   /// const FFV2_DS_FLAGS_REPAIR        = 0x00000008;
   /// typedef uint32_t            ffv2_ds_flags4;
~~~
{: #fig-ffv2_ds_flags4 title="The ffv2_ds_flags4" }

The ffv2_ds_flags4 (in {{fig-ffv2_ds_flags4}}) flags details the state
of the data servers.  With Erasure Coding algorithms, there are both
Systematic and Non-Systematic approaches.  In the Systematic, the bits
for integrity are placed amoungst the resulting transformed chunk.
Such an implementation would typically see FFV2_DS_FLAGS_ACTIVE and
FFV2_DS_FLAGS_SPARE data servers.  The FFV2_DS_FLAGS_SPARE ones allow the
client to repair a payload without enaging the metadata server.  I.e.,
if one of the FFV2_DS_FLAGS_ACTIVE did not respond to a WRITE_BLOCK,
the client could fail the chunk to the FFV2_DS_FLAGS_SPARE data server.

With the Non-Systematic approach, the data and integrity live on
different data servers.  Such an implementation would typically see
FFV2_DS_FLAGS_ACTIVE and FFV2_DS_FLAGS_PARITY data servers.  If the
implementation wanted to allow for local repair, it would also use
FFV2_DS_FLAGS_SPARE.

The FFV2_DS_FLAGS_REPAIR flag can be used by the metadata server to
inform the client that the indicated data server is a replacement data
server as far as existing data is concerned.  The client MUST repair the
file by using ROLLBACK_OPEN on the entire length of the file and both
decoding the existing data from the file and recoding the new data on
the indicated data server.  Whilst all data servers MUST be reserved,
only the data server(s) to be repaired MUST have the ROLLBACK_OPEN_SWAP
operation applied.  The remaining data servers can have their reservation
files dropped via ROLLBACK_CLOSE.

See {{Plank97}} for further reference to storage layouts for coding.

## ffv2_data_server4

~~~ xdr
   /// struct ffv2_data_server4 {
   ///     deviceid4               ffds_deviceid;
   ///     uint32_t                ffds_efficiency;
   ///     ffv2_file_info4         ffds_file_info<>;
   ///     fattr4_owner            ffds_user;
   ///     fattr4_owner_group      ffds_group;
   ///     ffv2_ds_flags4          ffds_flags;
   /// };
~~~
{: #fig-ffv2_data_server4 title="The ffv2_data_server4" }

The ffv2_data_server4 (in {{fig-ffv2_data_server4}}) describes a data
file and how to access it via the different NFS protocols.

## ffv2_coding_type_data4

~~~ xdr
   /// union ffv2_coding_type_data4 switch
   ///         (ffv2_coding_type4 fctd_coding) {
   ///     case FFV2_CODING_MIRRORED:
   ///         void;
   /// };
~~~
{: #fig-ffv2_coding_type_data4 title="The ffv2_coding_type_data4" }

The ffv2_coding_type_data4 (in {{fig-ffv2_coding_type_data4}}) describes
erasure coding type specific fields.  I.e., this is how the coding type
can communicate the need for counts of active, spare, parity, and repair
types of chunks.

## ffv2_key4

~~~ xdr
   /// typedef opaque ffv2_key4<>;
~~~
{: #fig-ffv2_key4 title="The ffv2_key4" }

The ffv2_key4 (in Figure {{fig-ffv2_key4}}) is a secret key known only
to the metadata server, data server, and client.  In the event of either
a data server restart or a dead client, it can be used to restablish a
connection via ROLLBACK_OPEN.

## ffv2_mirror4

~~~ xdr
   /// struct ffv2_mirror4 {
   ///     ffv2_coding_type_data4   ffm_coding_type_data;
   ///     ffv2_key4                ffm_key;
   ///     uint32_t                 ffm_client_id;
   ///     ffv2_data_server4        ffm_data_servers<>;
   /// };
~~~
{: #fig-ffv2_mirror4 title="The ffv2_mirror4" }

The ffv2_mirror4 (in {{fig-ffv2_mirror4}}) describes the Flexible File
Layout Version 2 specific fields.  The ffm_key allows the client to access
an already existing client file on the data servers and the ffm_client_id
tells the client which id to use when interacting with the data servers.

## ffv2_layout4

~~~ xdr
   /// struct ffv2_layout4 {
   ///     length4                 ffl_stripe_unit;
   ///     ffv2_mirror4            ffl_mirrors<>;
   ///     ffv2_flags4             ffl_flags;
   ///     uint32_t                ffl_stats_collect_hint;
   /// };
~~~
{: #fig-ffv2_layout4 title="The ffv2_layout4" }

The ffv2_layout4 (in {{fog-ffv2_layout4}}) describes the Flexible File
Layout Version 2.

## ffv2_layouthint4

~~~ xdr
   /// union ffv2_mirrors_hint switch (ffv2_coding_type4 ffmh_type) {
   ///     case FFV2_CODING_MIRRORED:
   ///         void;
   /// };
   ///
   /// struct ffv2_layouthint4 {
   ///     ffv2_coding_type4 fflh_supported_types<>;
   ///     ffv2_mirrors_hint fflh_mirrors_hint;
   /// };
~~~
{: #fig-ffv2_layouthint4 title="The ffv2_layouthint4" }

The ffv2_layouthint4 (in {{fig-ffv2_layouthint4}}) describes the
layout_hint (see Section 5.12.4 of {{RFC8881}}) that the client can
provide to the metadata server.

## Mixing of Coding Types

Multiple coding types can be present in a Flexible File Version 2 Layout
Type layout.  The ffv2_layout4 has an array of ffv2_mirror4, each of
which has a ffv2_coding_type4.  The main reason to allow for this is
to provide for either the assimilation of a non-erasure coded file to
an erasure coded file or the exporting of an erasure coded file to a
non-erasure coded file.

Assume there is an additional ffv2_coding_type4 of
FFV2_CODING_REED_SOLOMON and it needs 8 active chunks.  The user wants
to actively assimilate a regular file.  As such, a layout might be as
represented in {{fig-example_mixing}}}.  As this is an assimilation,
most of the data reads will be satisfied by READ (see Section 18.22 of
[RFC8881]) calls to index 0.  However, as this is also an active file,
there could also be CHUNK_READ (see Section 9.2) calls to the other
indexes.

~~~
            +---------------------------------------------------+
            | ffv2_layout4:                                     |
            +---------------------------------------------------+
            |     ffl_mirrors[0]:                               |
            |         ffm_data_servers:                         |
            |             ffv2_data_server4[0]                  |
            |                 ffds_flags: 0                     |
            |         ffm_coding: FFV2_CODING_MIRRORED          |
            +---------------------------------------------------+
            |     ffl_mirrors[1]:                               |
            |         ffm_data_servers:                         |
            |             ffv2_data_server4[0]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_ACTIVE  |
            |             ffv2_data_server4[1]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_ACTIVE  |
            |             ffv2_data_server4[2]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_ACTIVE  |
            |             ffv2_data_server4[3]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_ACTIVE  |
            |             ffv2_data_server4[4]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_PARITY  |
            |             ffv2_data_server4[5]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_PARITY  |
            |             ffv2_data_server4[6]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_SPARE   |
            |             ffv2_data_server4[7]                  |
            |                 ffds_flags: FFV2_DS_FLAGS_SPARE   |
            |     ffm_coding: FFV2_CODING_REED_SOLOMON          |
            +---------------------------------------------------+
~~~
{: #fig-example_mixing title="Example of Mixed Coding Types in a Layout" }

When performing I/O via a FFV2_CODING_MIRRORED coding type, the non-
transformed data will be used, Whereas with other coding types, a metadata
header and transformed block will be sent.  Further, when reading data
from the instance files, the client MUST be prepared to have one of
the coding types supply data and the other type not to supply data.
I.e., the CHUNK_READ call to the data servers in mirror 1 might return
rlr_eof set to true (see Figure 32), which indicates that there is no
data, where the READ call to the data server in mirror 0 might return
eof to be false, which indicates that there is data.  The client MUST
determine that there is in fact data.

An example use case is the active assimilation of a file to ensure
integrity.  As the client is helping to translated the file to the new
coding scheme, it is actively modifying the file.  As such, it might
be sequentially reading the file in order to translate.  The READ calls
to mirror 0 would be returning data and the CHUNK_READ calls to mirror
1 would not be returning data.  As the client overwrites the file, the
WRITE call and WRITE_SWAP_CHUNK call would have data sent to all of the
data servers.  Finally, if the client reads back a section which had been
modified earlier, both the READ and CHUNK_READ calls would return data.

# NFSv4.2 Operations Allowed to Data Files

   // In Flexible File Version 1 Layout Type, the emphasis was on NFSv3
   // DSes.  We limited the operations that clients could send to data
   // files to be COMMIT, READ, and WRITE.  We further limited the MDS
   // to GETATTR, SETATTR, CREATE, and REMOVE.  (Funny enough, this is
   // not mandated by {{I-D.haynes-nfsv4-flexfiles-v2}}.)  We need to call this out in this
   // draft and also we need to limit the NFSv4.2 operations.  Besides
   // the ones created here, consider: READ, WRITE, and COMMIT for
   // mirroring types and ALLOCATE, CLONE, COPY, DEALLOCATE, GETFH,
   // PUTFH, READ_PLUS, RESTOREFH, SAVEFH, SEEK, and SEQUENCE for all
   // types.
   //
   // -- TH
   // Of special merit is SETATTR.  Do we want to allow the clients to
   // be able to truncate the data files?  Which also brings up
   // DEALLOCATE.  Perhaps we want CHUNK_DEALLOCATE?  That way we can
   // swap out chunks with the client file.  CHUNK_DEALLOCATE_GUARD.
   // Really need to determine capabilities of XFS swap!
   //
   // -- TH

# Erasure Coding

Erasure Coding takes a data block and transforms it to a payload to send
to the data servers (see {{fig-encoding-data-block}}).  It generates a metadata header and
transformed block per data server.  The header is metadata information for
the transformed block.  From now on, the metadata is simply referred to
as the header and the transformed block as the chunk.  The payload of a
data block is the set of generated headers and chunks for that data block.

The guard is an unique identifier generated by the client to describe
the current write transaction (see Section 8.1).  The intent is to have
an unique and non-opauqe value for comparison.  The payload_id describes
the position within the payload.  Finally, the crc32 is the 32 bit crc
calculation of the header (with the crc32 field being 0) and the chunk.
By combining the two parts of the payload, integrity is ensured for both
the parts.

While the data block might have a length of 4kB, that does not necessarily
mean that the length of the chunk is 4kB.  That length is determined by
the erasure coding type algorithm.  For example, Reed Solomon might have
4kB chunks with the data integrity being compromised by parity chunks.
Another example would be the Mojette Transformation, which might have
1kB chunk lengths.

The payload contains redundancy which will allow the erasure coding type
algorithm to repair chunks in the payload as it is transformed back
to a data block (see {{fig-decoding-db}}).  A payload is consistent when all of
the contained headers share the same guard.  It has integrity when it
is consistent and the combinations of headers and chunks all pass the
crc32 checks.

The erasure coding algorithm itelf might not be sufficient to detect
errors in the chunks.  The crc32 checks will allow the data server to
detect chunks with issues and then the erasure decoding algorithm can
reconstruct the missing chunk.

## Encoding a Data Block

~~~
                     +-------------+
                     | data block  |
                     +-------+-----+
                             |
                             |
       +---------------------+-------------------------------+
       |            Erasure Encoding (Transform Forward)     |
       +---+----------------------+---------------------+----+
           |                      |                     |
           |                      |                     |
       +---+------------+     +---+------------+     +--+-------------+
       | HEADER         | ... | HEADER         | ... | HEADER         |
       +----------------+     +----------------+     +----------------+
       | guard:         | ... | guard:         | ... | guard:         |
       |   gen_id   : 3 | ... |   gen_id   : 3 | ... |   gen_id   : 3 |
       |   client_id: 6 | ... |   client_id: 6 | ... |   client_id: 6 |
       | payload_id : 0 | ... | payload_id : M | ... | payload_id : 5 |
       | crc32   :      | ... | crc32   :      | ... | crc32   :      |
       +----------------+     +----------------+     +----------------+
       | CHUNK          | ... | CHUNK          | ... | CHUNK          |
       +----------------+     +----------------+     +----------------+
       | data: ....     | ... | data: ....     | ... | data: ....     |
       +----------------+     +----------------+     +----------------+
         Data Server 1          Data Server N          Data Server 6
~~~
{: #fig-encoding-data-block title="Encoding a Data Block" }

Each data block of the file resident in the client's cache of the
file will be encoded into N different payloads to be sent to the data
servers as shown in {{fig-encoding-data-block}}.  As CHUNK_WRITE
(see Section 9.5) can encode multiple write_chunk4 into a single
transaction, a more accurate description of a CHUNK_WRITE might be as
in {{fig-example-chunk-write-args}}.

~~~
           +------------------------------------+
           | CHUNK_WRITEargs                    |
           +------------------------------------+
           | cwa_stateid: 0                     |
           | cwa_offset: 1                      |
           | cwa_stable: FILE_SYNC4             |
           | cwa_payload_id: 0                  |
           | cwa_owner:                         |
           |            co_guard:               |
           |                cg_gen_id   : 3     |
           |                cg_client_id: 6     |
           | cwa_chunk_size  :  1048            |
           | cwa_crc32s:                        |
           |         [0]:  0x32ef89             |
           |         [1]:  0x56fa89             |
           |         [2]:  0x7693af             |
           | cwa_chunks  :  ......              |
           +------------------------------------+
~~~
{: #fig-example-chunk-write-args title="Example of CHUNK_WRITE_args" }

This describes a 3 block write of data from an offset of 1 block in
the file.  As each block shares the cwa_owner, it is only presented once.
I.e., the data server will be able to construct the header for the i'th
chunk from the cwa_chunks from the cwa_payload_id, the cwa_owner, and
the i'th crc32 from the cw_crc32s.  The cwa_chunks are sent together as
a byte stream to increase performance.

Assuming that there were no issues, {{fig-example-chunk-write-res}}
illustrates the results.  The payload sequence id is implicit in the
CHUNK_WRITEargs.

~~~
           +-------------------------------+
           | CHUNK_WRITEresok              |
           +-------------------------------+
           | cwr_count: 3                  |
           | cwr_committed: FILE_SYNC4     |
           | cwr_writeverf: 0xf1234abc     |
           | cwr_owners[0]:                |
           |        co_chunk_id: 1         |
           |        co_guard:              |
           |            cg_gen_id   : 3    |
           |            cg_client_id: 6    |
           | cwr_owners[1]:                |
           |        co_chunk_id: 2         |
           |        co_guard:              |
           |            cg_gen_id   : 3    |
           |            cg_client_id: 6    |
           | cwr_owners[2]:                |
           |        co_chunk_id: 3         |
           |        co_guard:              |
           |            cg_gen_id   : 3    |
           |            cg_client_id: 6    |
           +-------------------------------+
~~~
{: #fig-example-chunk-write-res title="Example of CHUNK_WRITE_res" }

### Calculating the CRC32

~~~
           +---+----------------+
           | HEADER             |
           +--------------------+
           | guard:             |
           |   gen_id   : 7     |
           |   client_id: 6     |
           | payload_id : 0     |
           | crc32   : 0        |
           +--------------------+
           | CHUNK              |
           +--------------------+
           | data:  ....        |
           +--------------------+
                Data Server 1
~~~
{: #fig-calc-before title="CRC32 Before Calculation" }

Assuming the header and payload as in {{fig-calc-before}}, the crc32
needs to be calculated in order to fill in the cw_crc field.  In this
case, the crc32 is calculated over the 4 fields as shown in the header
and the cw_chunk.  In this example, it is calculated to be 0x21de8.
The resulting CHUNK_WRITE is shown in {{fig-calc-crc-after}}.

~~~
           +------------------------------------+
           | CHUNK_WRITEargs                    |
           +------------------------------------+
           | cwa_stateid: 0                     |
           | cwa_offset: 1                      |
           | cwa_stable: FILE_SYNC4             |
           | cwa_payload_id: 0                  |
           | cwa_owner:                         |
           |            co_guard:               |
           |                cg_gen_id   : 7     |
           |                cg_client_id: 6     |
           | cwa_chunk_size  :  1048            |
           | cwa_crc32s:                        |
           |         [0]:  0x21de8              |
           | cwa_chunks  :  ......              |
           +------------------------------------+
~~~
{: #fig-calc-crc-after title="CRC32 After Calculation" }

## Decoding a Data Block

~~~
         Data Server 1          Data Server N          Data Server 6
       +----------------+     +----------------+     +----------------+
       | HEADER         | ... | HEADER         | ... | HEADER         |
       +----------------+     +----------------+     +----------------+
       | guard:         | ... | guard:         | ... | guard:         |
       |   gen_id   : 3 | ... |   gen_id   : 3 | ... |   gen_id   : 3 |
       |   client_id: 6 | ... |   client_id: 6 | ... |   client_id: 6 |
       | payload_id : 0 | ... | payload_id : M | ... | payload_id : 5 |
       | crc32   :      | ... | crc32   :      | ... | crc32   :      |
       +----------------+     +----------------+     +----------------+
       | CHUNK          | ... | CHUNK          | ... | CHUNK          |
       +----------------+     +----------------+     +----------------+
       | data: ....     | ... | data: ....     | ... | data: ....     |
       +---+------------+     +--+-------------+     +-+--------------+
           |                     |                     |
           |                     |                     |
       +---+---------------------+---------------------+-----+
       |            Erasure Decoding (Transform Reverse)     |
       +---------------------+-------------------------------+
                             |
                             |
                     +-------+-----+
                     | data block  |
                     +-------------+
~~~
{: #fig-decoding-db title="Decoding a Data Block" }

When reading chunks via a READ operation, the client will decode them
into data blocks as shown in {{fig-decoding-db}}.

At this time, the client could detect issues in the integrity of the data.
The handling and repair are out of the scope of this document and MUST
be addressed in the document describing each erasure coding type.

### Checking the CRC32

~~~
           +------------------------------------+
           | CHUNK_READresok                    |
           +------------------------------------+
           | crr_eof: false                     |
           | crr_chunks[0]:                     |
           |        cr_crc: 0x21de8             |
           |        cr_owner:                   |
           |            co_guard:               |
           |                cg_gen_id   : 7     |
           |                cg_client_id: 6     |
           |        cr_chunk  :  ......         |
           +------------------------------------+
~~~
{: #fig-example-chunk-read-crc title="CRC32 on the Wire" }

Assuming the CHUNK_READ results as in {{fig-example-chunk-read-crc}},
the crc32 needs to be checked in order to ensure data integrity.
Conceptually, a header and payload can be built as shown in
{{fig-example-crc-checked}}.  The crc32 is calculated over the 4 fields as
shown in the header and the cr_chunk.  In this example, it is calculated
to be 0x21de8.  Thus this payload for the data server has data integrity.

~~~
           +---+----------------+
           | HEADER             |
           +--------------------+
           | guard:             |
           |   gen_id   : 7     |
           |   client_id: 6     |
           | payload_id  : 0    |
           | crc32    : 0       |
           +--------------------+
           | CHUNK              |
           +--------------------+
           | data:  ....        |
           +--------------------+
                Data Server 1
~~~
{: #fig-example-crc-checked title="CRC32 Being Checked" }

## Write Modes

There are two basic writing modes for erasure coding and they depend
the metadata server using FFV2_FLAGS_ONLY_ONE_WRITER in the ffl_flags
in the ffv2_layout4 (see Figure 10) to inform the client whether it
is the only writer to the file or not.  If it is the only writer,
then CHUNK_WRITE_SWAP can be used to write chunks.  In this scenario,
there is no write contention, but write holes can occur as the client
overwrites old data.  Thus the client does not need guarded writes,
but it does need the ability to rollback writes.  If it is not the
only writer, then CHUNK_WRITE_SWAP_GUARD MUST be used to write chunks.
In this scenario, the write holes can also be caused by multiple clients
writing to the same chunk.  Thus the client needs guarded writes to
prevent over writes and it does need the ability to rollback writes.

In both modes, clients MUST NOT overwrite payloads which already contain
inconsistency.  This directly follows from Section 4.4 and MUST be handled
as discussed there.  Once consistency in the payload has been detected,
the client can use those chunks as a basis for read/modify/update.

### Client File for Swapping Chunks

The client does not write chunks directly to the data file, instead
it first writes them to a per client temporary file and then swaps
them with the existing chunks in the data file.  This swapping allows
the client to rollback the changes if necessary.  The client file is
created by ROLLBACK_OPEN (see Section 9.6) and is persisted until a
ROLLBACK_CLOSE (see Section 9.8) is sent to the data server.  The chunks
in the client file MUST survive a data server restart.  Unlike normal
files on a metadata server, both data files and client files do not need
to be recovered by the client in the grace period.  After a data server
restart, the ROLLBACK_LIST (see Section 9.7) can be used to recover the
client filehandle.

   // Need to describe the header file and the fact that each client
   // file will also need a header file.  Do we need a header file if
   // our unit of measure is the chunk?  Can we just store the header in
   // front of the chunk?  This will depend on how the XFS swap
   // operates.  I.e., is it byte ranges or block based?
   //
   // -- TH

### Single Writer Mode

If the client detects that the FFV2_FLAGS_ONLY_ONE_WRITER is set, then
it uses CHUNK_WRITE_SWAP to write chunks first to the client file and
then swaps those chunks directly to the data file.  It then returns the
chunk owners for the chunks in the data file.  The old chunks stay in the
client file either until overwritten or deleted.  The issue with keeping
them indefinitely comes about during the repair process when the client
will have to consider all such chunks as possibly needing repair.

A client will exit the Single Writer Mode when the metadata
server recalls the layout and the subsequent LAYOUTGET returns the
FFV2_FLAGS_ONLY_ONE_WRITER as being not set.

#### Repairing Single Writer Payloads

The corruption which occurs is a mixture of new chunks and old chunks in
the payload.  If the client_ids do not match, then the chunks with the
non-matching id are the old chunks and the ones with the same client_id
are the new chunks.  The smaller gen_id are always the older chunks.

The write hole scenarios that can occur with the single writer are:

1.  The client restarts after it has sent M of the N CHUNK_WRITE_SWAP.

2.  The data server does not receive the CHUNK_WRITE_SWAP.

3.  The data server does not reply to the CHUNK_WRITE_SWAP, the client
has a FFV2_DS_FLAGS_SPARE, it writes to it, and then the original data
server responds.

4.  Any combination of the above occuring at the same time.

When the client restarts in the middle of the parallel writes to the data
servers, the original client might not be the one which discovers the
write hole.  It may be the metadata server has tasked a client to scan
for write holes after it detected that the original client restarted.
As such, the repair client would be using HEADER_READ to determine there
was a write hole for this chunk in the payload.  The repair action here
depends on whether there are enough new chunks in the payload for the
client to decode the data block.  If there are, then the old chunks
can be erased.  If there are not, then the new chunks are rolled back
via CHUNK_SWAP.

If the data server never receives the write, either the data server was
partitioned or temporarily down (rebooting or administrative action).
If a FFV2_DS_FLAGS_SPARE data server was made available to the client,
then the repair action it to write the chunk to a spare.  If there are
not enough spares available to get consistency, then the repair option
is to rollback the written chunks via CHUNK_SWAP.

If there are a FFV2_DS_FLAGS_ACTIVE and a FFV2_DS_FLAGS_SPARE data
servers with the same chunk (their payload_ids match), then the repair
action is to remove the chunk from the FFV2_DS_FLAGS_SPARE data server.
The reason this MUST be done is that an overwrite would only go to the
FFV2_DS_FLAGS_ACTIVE data server, which might cause a client to get
confused when there are two different chunks with the same payload_id.
The client SHOULD be able to figure this out, but a double failure might
complicate the subsequent repair of the payload.

If there are multiple failures of client and data server restarts, the
repair client will determine if their is consistency in the payload,
in which case it may decide to make no changes, or if not, then it rolls
back the chunks via CHUNK_SWAP.


   // And every subsequent CHUNK_READ will report an error, leading to
   // much hand wrangling and little progress.  Do we hole punch the
   // ones that are not there?  Or just rollback in either case here?
   //
   // -- TH

### Mutliple Writer Mode

If the client detects that the FFV2_FLAGS_ONLY_ONE_WRITER is not set,
then it uses CHUNK_WRITE_SWAP_GUARD to write chunks first to the client
file and then provisionally swaps those chunks directly to the data file.
The swap is provisional based on two states:

matching of the guard values:

:  The CHUNK_WRITE_SWAP_GUARD sends a guard value which is checked
against the persisted guard values on the chunk.  If the guard values
match, then the swap can proceed to the next check.  If the values do
not match, then the data server MUST set the chunk as locked and persist
that file attribute.

locking state of the chunk:

:  If the chunk is locked, then no other chunk can be swapped in on
top of it.  This prevents racing clients from overwriting each other
and possibly losing the original chunk contents.  Once it is locked,
either a CHUNK_UNLOCK operation can unlock it or a CHUNK_SWAP with the
csa_unlock flag set unlocks it after swapping the chunks.

CHUNK_WRITE_SWAP_GUARD does not return any error in the case that any
one of the chunks it writes fails due to either of the above criteria.
It simply returns the chunk owners for the chunks in the data file.
The client can easily infer that a specfic chunk is locked if the guard
did not change on that chunk.  Once a client determines that a chunk is
locked, it MUST NOT rewrite to that chunk unless it has been informed
by the metadata server via CB_CHUNK_REPAIR to repair the chunk or by
inspection via HEADER_READ it determines that the locking state is gone.

The old chunks stay in the client file either until overwritten or
deleted.  The issue with keeping them indefinitely comes about during
the repair process when the client will have to consider all such chunks
as possibly needing repair.

A client will exit the Multiple Writer Mode when the metadata
server recalls the layout and the subsequent LAYOUTGET returns the
FFV2_FLAGS_ONLY_ONE_WRITER as being set.

### Repairing Multiple Writer Payloads

When writing chunks, the write either succeeds for the client or fails.
If all chunk writes in the payload succeed for the client, then it can
delete the old chunks out of the swap file.  If all chunk writes in
the payload fail for the client, then it if it knows the data block is
entirely new data that it can abandon the write attempt or retry with an
overwrite.  If it knows that the data block update was a partial update,
then it can re-read the chunks from the data server and attempt to rewrite
the chunks.  In any of these cases, the failure MUST be reported to the
metadata server via CHUNK_ERROR.  Even though the clients can easily
determine the winner, there are two scenarios which can lead to deadlock
in the repair process:

winning client restarts or permamently goes away:

:  If the clients all determine that the lowest or highest winning
client_id is the one to repair the chunks, then if it restarts or
permamently goes away, the other clients will be stuck waiting for it
to act.

winning client is unaware of locked chunks:

:  If the winning client succeed in writing all chunks in the payload,
and another client failed against each guarded write, then the winning
client is unaware that the chunks are locked.  And while the losing
clients could detect the consistency and attempt to CHUNK_UNLOCK the
chunk, that client could restart or go away permamently.

Once the metadata server gets the CHUNK_ERROR, it selects a client
to repair the chunk.  It sends a CB_CHUNK_REPAIR, which contains both
a client_id and a key to use whilst repairing the chunk.  It will use
these values to override what it gets back in the LAYOUTGET.  The client
then uses CHUNK_SWAP(unlock) from the client file of the winner to get
a consistent payload.  If all chunks are already consistent, then it
CHUNK_UNLOCKs all the chunks to release the lock.

   // client_id and key for each chunk?  I.e., it can repair many?
   //
   // -- TH

If the metadata server detects that the client restarts, then it reissues
the CB_CHUNK_REPAIR to either that client when it comes back online or
to any other client.

All clients which have detected the inconsistency can determine when
they can start accessing the chunk via HEADER_READ.  Once the lock goes
away, the clients can CHUNK_READ the chunk to decide if they are going
to update the chunk.

## Reading Chunks

The client reads chunks from the data file via CHUNK_READ.  The number
of chunks in the payload that need to be consistent depend on both the
Erasure Coding Type and the level of protection selected.  If the client
has enough consistent chunks in the payload, then it can proceed to
use them to build a data block.  If it does not have enough consistent
chunks in the payload, then it can either decide to return a LAYOUTERROR
of NFS4ERR_PAYLOAD_NOT_CONSISTENT to the metadata server or it can retry
the CHUNK_READ until there are enough consistent chunks in the payload.

As another client might be writing to the chunks as they are being read,
it is entirely possible to read the chunks while they are not consistent.
As such, it might even be the non-consistent chunks which contain the
new data and a better action than building the data block is to retry
the CHUNK_READ to see if new chunks are overwritten.

## Whole File Repair


   // Describe how a repair client can be assigned with missing
   // FFV2_DS_FLAGS_ACTIVE data servers and a number of
   // FFV2_DS_FLAGS_REPAIR data servers.  Then the client will either
   // move chunks from FFV2_DS_FLAGS_SPARE data servers to the
   // FFV2_DS_FLAGS_REPAIR data servers or reconstruct the chunks for
   // the FFV2_DS_FLAGS_REPAIR based on the decoded data blocks, The
   // client indicates success by returning the layout.
   //
   // -- TH


   // For a slam dunk, introduce the concept of a proxy repair client.
   // I.e., the client appears as a single FFV2_CODING_MIRRORED file to
   // other clients.  As it receives WRITEs, it encodes them to the real
   // set of data servers.  As it receives READs, it decodes them from
   // the real set of data servers.  Once the proxy repair is finished,
   // the metadata server will start pushing out layouts for the real
   // set of data servers.
   //
   // -- TH

#  New NFSv4.2 Error Values

~~~ xdr
   ///
   /// /* Erasure Coding errors start here */
   ///
   /// NFS4ERR_XATTR2BIG      = 10096,/* xattr value is too big  */
   /// NFS4ERR_CODING_NOT_SUPPORTED
   ///    = 10097,/* Coding Type unsupported  */
   /// NFS4ERR_PAYLOAD_NOT_CONSISTENT= 10098/* payload inconsitent  */
   ///
~~~
{: #fig-errors-xdr title="Errors XDR" }

   The new error codes are shown in {{fig-errors-xdr}}.

## Error Definitions

 | Error                          | Number | Description   |
 |---
 | NFS4ERR_CODING_NOT_SUPPORTED   | 10097  | Section 5.1.1 |
 | NFS4ERR_PAYLOAD_NOT_CONSISTENT | 10098  | Section 5.1.2 |
{: #tbl-protocol-errors title="X"}

### NFS4ERR_CODING_NOT_SUPPORTED (Error Code 10097)

The client requested a ffv2_coding_type4 which the metadata server
does not support.  I.e., if the client sends a layout_hint requesting
an erasure coding type that the metadata server does not support,
this error code can be returned.  The client might have to send the
layout_hint several times to determine the overlapping set of supported
erasure coding types.

### NFS4ERR_PAYLOAD_NOT_CONSISTENT (Error Code 10098)

The client encountered a payload in which the blocks were inconsistent
and stays inconsistent.  As the client can not tell if another client
is actively writing, it informs the metadata server of this error
via LAYOUTERROR4.  The metadata server can then arrange for repair of
the file.

## Operations and Their Valid Errors

The operations and their valid errors are presented in
{{tbl-ops-and-errors}}.  All error codes not defined in this document
are defined in Section 15 of {{RFC8881}} and Section 11 of {{RFC7862}}.

 | Operation             | Errors                                   |
 | ---
 | ROLLBACK_OPEN         | NFS4ERR_ACCESS, NFS4ERR_ADMIN_REVOKED, NFS4ERR_BADXDR, NFS4ERR_BAD_STATEID, NFS4ERR_DEADSESSION, NFS4ERR_DELAY, NFS4ERR_DELEG_REVOKED, NFS4ERR_DQUOT, NFS4ERR_EXPIRED, NFS4ERR_FBIG, NFS4ERR_FHEXPIRED, NFS4ERR_GRACE, NFS4ERR_INVAL, NFS4ERR_IO, NFS4ERR_ISDIR, NFS4ERR_LOCKED, NFS4ERR_MOVED, NFS4ERR_NOFILEHANDLE, NFS4ERR_NOSPC, NFS4ERR_NOTSUPP, NFS4ERR_OLD_STATEID, NFS4ERR_OPENMODE, NFS4ERR_OP_NOT_IN_SESSION, NFS4ERR_PNFS_IO_HOLE, NFS4ERR_PNFS_NO_LAYOUT, NFS4ERR_REP_TOO_BIG, NFS4ERR_REP_TOO_BIG_TO_CACHE, NFS4ERR_REQ_TOO_BIG, NFS4ERR_RESERVATION_CONFLICT, NFS4ERR_RETRY_UNCACHED_REP, NFS4ERR_ROFS, NFS4ERR_SERVERFAULT, NFS4ERR_STALE, NFS4ERR_SYMLINK, NFS4ERR_TOO_MANY_OPS, NFS4ERR_WRONG_TYPE |
 | ROLLBACK_LIST         | NFS4ERR_ACCESS, NFS4ERR_ADMIN_REVOKED, NFS4ERR_BADXDR, NFS4ERR_DEADSESSION, NFS4ERR_DELAY, NFS4ERR_DELEG_REVOKED, NFS4ERR_FHEXPIRED, NFS4ERR_GRACE, NFS4ERR_INVAL, NFS4ERR_IO, NFS4ERR_ISDIR, NFS4ERR_LOCKED, NFS4ERR_MOVED, NFS4ERR_NOENT, NFS4ERR_NOFILEHANDLE, NFS4ERR_NOTSUPP, NFS4ERR_OPENMODE, NFS4ERR_OP_NOT_IN_SESSION, NFS4ERR_PNFS_IO_HOLE, NFS4ERR_PNFS_NO_LAYOUT, NFS4ERR_REP_TOO_BIG, NFS4ERR_REP_TOO_BIG_TO_CACHE, NFS4ERR_REQ_TOO_BIG, NFS4ERR_RESERVATION_CONFLICT, NFS4ERR_RETRY_UNCACHED_REP, NFS4ERR_SERVERFAULT, NFS4ERR_STALE, NFS4ERR_SYMLINK, NFS4ERR_TOO_MANY_OPS, NFS4ERR_WRONG_TYPE                       |
 | ROLLBACK_OPEN_RECOVER | NFS4ERR_ACCESS, NFS4ERR_ADMIN_REVOKED, NFS4ERR_BADXDR, NFS4ERR_DELAY, NFS4ERR_FHEXPIRED, NFS4ERR_GRACE, NFS4ERR_INVAL, NFS4ERR_IO, NFS4ERR_MOVED, NFS4ERR_NOENT, NFS4ERR_NOFILEHANDLE, NFS4ERR_NOTSUPP, NFS4ERR_OP_NOT_IN_SESSION, NFS4ERR_PERM, NFS4ERR_REP_TOO_BIG, NFS4ERR_REP_TOO_BIG_TO_CACHE, NFS4ERR_REQ_TOO_BIG, NFS4ERR_RETRY_UNCACHED_REP, NFS4ERR_STALE, NFS4ERR_SYMLINK, NFS4ERR_TOO_MANY_OPS, NFS4ERR_WRONG_CRED, NFS4ERR_WRONG_TYPE   |
 | ROLLBACK_CLOSE        | NFS4ERR_ACCESS, NFS4ERR_ADMIN_REVOKED, NFS4ERR_BADXDR, NFS4ERR_DELAY, NFS4ERR_FHEXPIRED, NFS4ERR_GRACE, NFS4ERR_INVAL, NFS4ERR_IO, NFS4ERR_MOVED, NFS4ERR_NOENT, NFS4ERR_NOFILEHANDLE, NFS4ERR_NOTSUPP, NFS4ERR_OP_NOT_IN_SESSION, NFS4ERR_PERM, NFS4ERR_REP_TOO_BIG, NFS4ERR_REP_TOO_BIG_TO_CACHE, NFS4ERR_REQ_TOO_BIG, NFS4ERR_RETRY_UNCACHED_REP, NFS4ERR_STALE, NFS4ERR_SYMLINK, NFS4ERR_TOO_MANY_OPS, NFS4ERR_WRONG_CRED, NFS4ERR_WRONG_TYPE   |
{: #tbl-ops-and-errors title="Operations and Their Valid Errors"}

## Callback Operations and Their Valid Errors

The callback operations and their valid errors are presented in
{{tbl-cb-ops-and-errors}}.  All error codes not defined in this document
are defined in Section 15 of {{RFC8881}} and Section 11 of {{RFC7862}}.

 | Callback Operation| Errors                                       |
 | ---
 | CB_CHUNK_REPAIR | NFS4ERR_BADXDR, NFS4ERR_BAD_STATEID, NFS4ERR_DEADSESSION, NFS4ERR_DELAY, NFS4ERR_CODING_NOT_SUPPORTED, NFS4ERR_INVAL, NFS4ERR_IO, NFS4ERR_ISDIR, NFS4ERR_LOCKED, NFS4ERR_NOTSUPP, NFS4ERR_OLD_STATEID, NFS4ERR_SERVERFAULT, NFS4ERR_STALE,          |
{: #tbl-cb-ops-and-errors title="Callback Operations and Their Valid Errors"}

## Errors and the Operations That Use Them

The operations and their valid errors are presented in
{{tbl-errors-and-ops}}.  All operations not defined in this document
are defined in Section 18 of {{RFC8881}} and Section 15 of {{RFC7862}}.

 | Error                            | Operations                  |
 | ---
 | NFS4ERR_CODING_NOT_SUPPORTED     | CB_CHUNK_REPAIR, LAYOUTGET  |
 | NFS4ERR_RESERVATION_CONFLICT     | ROLLBACK_OPEN               |
 | NFS4ERR_RESERVATION_FILE         | CLOSE, LOCK, LOCKT, LOCKU, LOOKUP, LOOKUPP, OPEN, OPENATTR, READLINK, REMOVE, RENAME, SETATTR, VERIFY     |
 | NFS4ERR_RESERVATION_HELD         | COMMIT, READ, WRITE         |
 | NFS4ERR_RESERVATION_OUT_OF_RANGE | COMMIT, READ, WRITE         |
{: #tbl-errors-and-ops title="Errors and the Operations That Use Them"}

# EXCHGID4_FLAG_USE_PNFS_DS

~~~ xdr
   /// const EXCHGID4_FLAG_USE_ERASURE_DS      = 0x00100000;
~~~
{: #fig-EXCHGID4_FLAG_USE_PNFS_DS title="The EXCHGID4_FLAG_USE_PNFS_DS" }

When a data server connects to a metadata server it can via
EXCHANGE_ID (see Section 18.35 of {{RFC8881}}) state its pNFS role.
The data server can use EXCHGID4_FLAG_USE_ERASURE_DS (see
{{fig-EXCHGID4_FLAG_USE_PNFS_DS}}) to indicate that it supports the
new NFSv4.2 operations introduced in this document.  Section 13.1
of {{RFC8881}} describes the interaction of the various pNFS roles
masked by EXCHGID4_FLAG_MASK_PNFS.  However, that does not mask out
EXCHGID4_FLAG_USE_ERASURE_DS.  I.e., EXCHGID4_FLAG_USE_ERASURE_DS can
be used in combination with all of the pNFS flags.

If the data server sets EXCHGID4_FLAG_USE_ERASURE_DS during the
EXCHANGE_ID operation, then it MUST support all of the operations
in {{tbl-protocol-ops}}.  Further, this support is orthogonal to the
Erasure Coding Type selected.  The data server is unaware of which type
is driving the I/O.

# New NFSv4.2 Attributes

## Attribute 88: fattr4_coding_block_size

~~~ xdr
   /// typedef size_t                    fattr4_coding_block_size;
   ///
   /// const FATTR4_CODING_BLOCK_SIZE  = 88;
   ///
~~~
{: #fig-X title="The X" }

                Figure 23: XDR for fattr4_coding_block_size

   The new attribute fattr4_coding_block_size (see Figure 23) is an
   OPTIONAL to NFSv4.2 attribute which MUST be supported if the metadata
   server supports the Flexible File Version 2 Layout Type.  By querying
   it, the client can determine the data block size it is to use when
   coding the data blocks to chunks.

# New NFSv4.2 Common Data Structures

## chunk_guard4

~~~ xdr
   /// struct chunk_guard4 {
   ///     uint32_t   cg_gen_id;
   ///     uint32_t   cg_client_id;
   /// };
~~~
{: #fig-X title="The X" }

                      Figure 24: XDR for chunk_guard4

   The chunk_guard4 (see Figure 24) is effectively a 64 bit value, with
   the upper 32 bits, cg_gen_id, being the current generation id of the
   chunk on the DS and the lower 32 bits, cg_client_id, being an unique
   id established when the client did the EXCHANGE_ID operation (see
   Section 18.35 of {{RFC8881}}) with the metadata server.  The lower 32
   bits are set passed back in the LAYOUTGET operation (see
   Section 18.43 of {{RFC8881}}) as the fml_client_id (see Section 2.9).

## chunk_owner4

~~~ xdr
   /// struct chunk_owner4 {
   ///     chunk_guard4   co_guard;
   ///     uint32_t       co_id;
   /// };
~~~
{: #fig-X title="The X" }

                    Figure 25: XDR for code_chunk_owner4

   The chunk_owner4 (see Figure 25) is used to determine when and by
   whom a block was written.  The co_id is used to identify the block
   and MUST be the index of the chunk within the file.  I.e., it is the
   offset of the start of the chunk divided by the chunk length.  The
   co_guard is a chunk_guard4 (see Section 8.1 used to identify a given
   transaction.

   The co_guard is like the change attribute (see Section 5.8.1.4 of
   {{RFC8881}}) in that each chunk write by a given client has to have an
   unique co_guard.  I.e., it can be determined which transaction across
   all data files that a chunk corresponds.

# New NFSv4.2 Operations

~~~ xdr
   ///
   /// /* New operations for Erasure Coding start here */
   ///
   ///  OP_CHUNK_COMMIT        = 77,
   ///  OP_CHUNK_ERROR         = 78,
   ///  OP_CHUNK_LOCK          = 79,
   ///  OP_CHUNK_READ          = 80,
   ///  OP_CHUNK_REPAIRED      = 81,
   ///  OP_CHUNK_SWAP          = 82,
   ///  OP_CHUNK_UNLOCK        = 83,
   ///  OP_CHUNK_WRITE         = 84,
   ///  OP_CHUNK_WRITE_SWAP    = 85,
   ///  OP_CHUNK_WRITE_SWAP_GUARD = 86,
   ///  OP_GUARD_SWAP          = 87,
   ///  OP_HEADER_READ         = 88,
   ///  OP_ROLLBACK_CLOSE      = 89,
   ///  OP_ROLLBACK_LIST       = 90,
   ///  OP_ROLLBACK_OPEN       = 91,
   ///  OP_SWAP                = 92,
   ///
~~~
{: #fig-X title="The X" }

                         Figure 26: Operations XDR

   | Operation              | Number | Target Server     | Description |
   | ---
   | CHUNK_COMMIT           | 77     | DS                | Section 9.1 |
   | CHUNK_ERROR            | 78     | MDS               | Section 9.2 |
   | CHUNK_LOCK             | 79     | DS                | Section 9.2 |
   | CHUNK_READ             | 80     | DS                | Section 9.2 |
   | CHUNK_REPAIRED         | 81     | MDS               | Section 9.2 |
   | CHUNK_SWAP             | 82     | DS                | Section 9.2 |
   | CHUNK_UNLOCK           | 83     | DS                | Section 9.2 |
   | CHUNK_WRITE            | 84     | DS                | Section 9.5 |
   | CHUNK_WRITE_SWAP       | 85     | DS                | Section 9.5 |
   | CHUNK_WRITE_SWAP_GUARD | DS     | 86                | Section 9.5 |
   | GUARD_SWAP             | 87     | DS                | Section 9.5 |
   | HEADER_READ            | 88     | DS                | Section 9.3 |
   | ROLLBACK_CLOSE         | 89     | DS                | Section 9.7 |
   | ROLLBACK_LIST          | 90     | DS                | Section 9.7 |
   | ROLLBACK_OPEN          | 91     | DS                | Section 9.7 |
   | SWAP                   | 92     | non-pNFS, MDS, DS         | Section 9.7 |
{: #tbl-protocol-ops title="X"}

## Operation 77: CHUNK_COMMIT - Activate Cached Chunk Data

### ARGUMENTS

~~~ xdr
   /// struct CHUNK_COMMIT4args {
   ///     /* CURRENT_FH: file */
   ///     offset4         cca_offset;
   ///     count4          cca_count;
   ///     chunk_owner4    cca_chunks<>;
   /// };
~~~
{: #fig-X title="The X" }

                    Figure 27: XDR for CHUNK_COMMIT4args

### RESULTS

~~~ xdr
   /// struct CHUNK_COMMIT4resok {
   ///     verifier4       ccr_writeverf;
   /// };
~~~
{: #fig-X title="The X" }

                   Figure 28: XDR for CHUNK_COMMIT4resok

~~~ xdr
   /// union CHUNK_COMMIT4res switch (nfsstat4 ccr_status) {
   ///     case NFS4_OK:
   ///         CHUNK_COMMIT4resok   ccr_resok4;
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                    Figure 29: XDR for CHUNK_COMMIT4res

### DESCRIPTION

   CHUNK_COMMIT is COMMIT (see Section 18.3 of {{RFC8881}}) with
   additional semantics over the chunk_owner activating the blocks.  As
   such, all of the normal semantics of COMMIT directly apply.

   The main difference between the two operations is that CHUNK_COMMIT
   works on blocks and not a raw data stream.  As such cca_offset is the
   starting block offset in the file and not the byte offset in the
   file.  Some erasure coding types can have different block sizes
   depending on the block type.  Further, cca_count is a count of blocks
   to activate and not bytes to activate.

   Further, while it may appear that the combination of cca_offset and
   cca_count are redundant to cca_chunks, the purpose of cca_chunks is
   to allow the data server to differentiate between potentially
   multiple pending blocks.

## Operation 78: CHUNK_READ - Read Chunks from File

### ARGUMENTS

~~~ xdr
   /// struct CHUNK_READ4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4    cra_stateid;
   ///     offset4     cra_offset;
   ///     count4      cra_count;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 30

### RESULTS

~~~ xdr
   /// struct read_chunk4 {
   ///     uint32_t        cr_crc;
   ///     uint32_t        cr_effective_len;
   ///     chunk_owner4    cr_owner;
   ///     uint32_t        cr_payload_id;
   ///     opaque          cr_chunk<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 31

~~~ xdr
   /// struct CHUNK_READ4resok {
   ///     bool        crr_eof;
   ///     read_chunk4 crr_chunks<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 32

~~~ xdr
   /// union CHUNK_READ4res switch (nfsstat4 crr_status) {
   ///     case NFS4_OK:
   ///          CHUNK_READ4resok     crr_resok4;
   ///     default:
   ///          void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 33

### DESCRIPTION

   CHUNK_READ is READ (see Section 18.22 of {{RFC8881}}) with additional
   semantics over the chunk_owner.  As such, all of the normal semantics
   of READ directly apply.

   The main difference between the two operations is that CHUNK_READ
   works on blocks and not a raw data stream.  As such cra_offset is the
   starting block offset in the file and not the byte offset in the
   file.  Some erasure coding types can have different block sizes
   depending on the block type.  Further, cra_count is a count of blocks
   to read and not bytes to read.

   When reading a set of blocks across the data servers, it can be the
   case that some data servers do not have any data at that location.
   In that case, the server either returns crr_eof if the cra_offset
   exceeds the number of blocks that the data server is aware or it
   returns an empty block for that block.

   For example, in Figure 34, the client asks for 4 blocks starting with
   the 3rd block in the file.  The second data server responds as in
   Figure 35.  The client would read this as there is valid data for
   blocks 2 and 4, there is a hole at block 3, and there is no data for
   block 5.  The data server MUST calculate a valid cr_crc for block 3
   based on the generated fields.

~~~
                   Data Server 2
           +--------------------------------+
           | CHUNK_READ4args                |
           +--------------------------------+
           | cra_stateid: 0                 |
           | cra_offset: 2                  |
           | cra_count: 4                   |
           +----------+---------------------+
~~~
{: #fig-X title="The X" }

                                 Figure 34

~~~
                   Data Server 2
           +--------------------------------+
           | CHUNK_READ4resok               |
           +--------------------------------+
           | crr_eof: true                  |
           | crr_chunks[0]:                 |
           |     cr_crc: 0x3faddace         |
           |     cr_owner:                  |
           |         co_chunk_id: 2         |
           |         co_guard:              |
           |             cg_gen_id   : 3    |
           |             cg_client_id: 6    |
           |     cr_payload_id: 1           |
           |     cr_chunk: ....             |
           | crr_chunks[0]:                 |
           |     cr_crc: 0xdeade4e5         |
           |     cr_owner:                  |
           |         co_chunk_id: 3         |
           |         co_guard:              |
           |             cg_gen_id   : 0    |
           |             cg_client_id: 0    |
           |     cr_payload_id: 1           |
           |     cr_chunk: 0000...00000     |
           | crr_chunks[0]:                 |
           |     cr_crc: 0x7778abcd         |
           |     cr_owner:                  |
           |         co_chunk_id: 4         |
           |         co_guard:              |
           |             cg_gen_id   : 3    |
           |             cg_client_id: 6    |
           |     cr_payload_id: 1           |
           |     cr_chunk: ....             |
           +--------------------------------+
~~~
{: #fig-X title="The X" }

                                 Figure 35

## Operation 79: HEADER_READ - Read Chunk Header from File

### ARGUMENTS

~~~ xdr
   /// struct HEADER_READ4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4    hra_stateid;
   ///     offset4     hra_offset;
   ///     count4      hra_count;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 36

### RESULTS

~~~ xdr
   /// struct HEADER_READ4resok {
   ///     bool            hrr_eof;
   ///     chunk_owner4    hrr_chunks<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 37

~~~ xdr
   /// union HEADER_READ4res switch (nfsstat4 hrr_status) {
   ///     case NFS4_OK:
   ///         HEADER_READ4resok     hrr_resok4;
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 38

### DESCRIPTION

   HEADER_READ differs from CHUNK_READ in that it only reads chunk
   headers in the desired data range.

## Operation 80: ROLLBACK_CHUNK - Rollback Cached Chunk Data

### ARGUMENTS

~~~ xdr
   /// struct ROLLBACK_CHUNK4args {
   ///     /* CURRENT_FH: file */
   ///     offset4         cra_offset;
   ///     count4          cra_count;
   ///     chunk_owner4    cra_chunks<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 39

### RESULTS

~~~ xdr
   /// struct ROLLBACK_CHUNK4resok {
   ///     verifier4       crr_writeverf;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 40

~~~ xdr
   /// union ROLLBACK_CHUNK4res switch (nfsstat4 crr_status) {
   ///     case NFS4_OK:
   ///         ROLLBACK_CHUNK4resok   crr_resok4;
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 41

### DESCRIPTION

   ROLLBACK_CHUNK is a new form like COMMIT (see Section 18.3 of
   {{RFC8881}}) with additional semantics over the chunk_owner the rolling
   back the writing of blocks.  As such, all of the normal semantics of
   COMMIT directly apply.

   The main difference between the two operations is that ROLLBACK_CHUNK
   works on blocks and not a raw data stream.  As such cra_offset is the
   starting block offset in the file and not the byte offset in the
   file.  Some erasure coding types can have different block sizes
   depending on the block type.  Further, cra_count is a count of blocks
   to rollback and not bytes to rollback.

   Further, while it may appear that the combination of cra_offset and
   cra_count are redundant to cra_chunks, the purpose of cra_chunks is
   to allow the data server to differentiate between potentially
   multiple pending blocks.

   ROLLBACK_CHUNK deletes prior CHUNK_WRITE transactions.  In case of
   write holes, it allows the client to undo transactions to repair the
   file.

## Operation 81: CHUNK_WRITE - Write Chunks to File

### ARGUMENTS

~~~ xdr
   /// union write_chunk_guard4 (bool cwg_check) {
   ///     case TRUE:
   ///         chunk_guard4   cwg_guard;
   ///     case FALSE:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 42

~~~ xdr
   /// struct CHUNK_WRITE4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4           cwa_stateid;
   ///     offset4            cwa_offset;
   ///     stable_how4        cwa_stable;
   ///     chunk_owner4       cwa_owner;
   ///     uint32_t           cwa_payload_id;
   ///     write_chunk_guard4 cwa_guard;
   ///     uint32_t           cwa_chunk_size;
   ///     uint32_t           cwa_crc32s<>;
   ///     opaque             cwa_chunks<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 43

### RESULTS

~~~ xdr
   /// struct CHUNK_WRITE4resok {
   ///     count4          cwr_count;
   ///     stable_how4     cwr_committed;
   ///     verifier4       cwr_writeverf;
   ///     chunk_owner4    cwr_owners<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 44

~~~ xdr
   /// union CHUNK_WRITE4res switch (nfsstat4 cwr_status) {
   ///     case NFS4_OK:
   ///         CHUNK_WRITE4resok    cwr_resok4;
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 45

### DESCRIPTION

   CHUNK_WRITE is WRITE (see Section 18.32 of {{RFC8881}}) with additional
   semantics over the chunk_owner and the activation of blocks.  As
   such, all of the normal semantics of WRITE directly apply.

   The main difference between the two operations is that CHUNK_WRITE
   works on blocks and not a raw data stream.  As such cwa_offset is the
   starting block offset in the file and not the byte offset in the
   file.  Some erasure coding types can have different block sizes
   depending on the block type.  Further, cwr_count is a count of
   written blocks and not written bytes.

   If cwa_stable is FILE_SYNC4, the data server MUST commit the written
   header and block data plus all file system metadata to stable storage
   before returning results.  This corresponds to the NFSv2 protocol
   semantics.  Any other behavior constitutes a protocol violation.  If
   cwa_stable is DATA_SYNC4, then the data server MUST commit all of the
   header and block data to stable storage and enough of the metadata to
   retrieve the data before returning.  The data server implementer is
   free to implement DATA_SYNC4 in the same fashion as FILE_SYNC4, but
   with a possible performance drop.  If cwa_stable is UNSTABLE4, the
   data server is free to commit any part of the header and block data
   and the metadata to stable storage, including all or none, before
   returning a reply to the client.  There is no guarantee whether or
   when any uncommitted data will subsequently be committed to stable
   storage.  The only guarantees made by the data server are that it
   will not destroy any data without changing the value of writeverf and
   that it will not commit the data and metadata at a level less than
   that requested by the client.

   The activation of header and block data interacts with the
   co_activated for each of the written blocks.  If the data is not
   committed to stable storage then the co_activated field MUST NOT be
   set to true.  Once the data is committed to stable storage, then the
   data server can set the block's co_activated if one of these
   conditions apply:

   *  it is the first write to that block and the
      CHUNK_WRITE_FLAGS_ACTIVATE_IF_EMPTY flag is set

   *  the CHUNK_COMMIT is issued later for that block.

   There are subtle interactions with write holes caused by racing
   clients.  One client could win the race in each case, but because it
   used a cwa_stable of UNSTABLE4, the subsequent writes from the second
   client with a cwa_stable of FILE_SYNC4 can be awarded the
   co_activated being set to true for each of the blocks in the payload.

   Finally, the interaction of cwa_stable can cause a client to
   mistakenly believe that by the time it gets the response of
   co_activated of false, that the blocks are not activated.  A
   subsequent CHUNK_READ or HEADER_READ might show that the co_activated
   is true without any interaction by the client via CHUNK_COMMIT.

#### Guarding the Write

   A guarded CHUNK_WRITE is when the writing of a block MUST fail if
   cwa_guard.cwg_check is set and the target chunk does not have both
   the same gen_id cwa_guard.as the cwg_guard.cg_gen_id and the same
   cwa_guard.cg_gen_id as the cwa_guard.cwg_guard.cg_gen_id.  This is
   useful in read-update-write scenarios.  The client reads a block,
   updates it, and is prepared to write it back.  It guards the write
   such that if another writer has modified the block, the data server
   will reject the modification.

   As the chunk_guard4 (see Figure 24 does not have a chunk_id and the
   CHUNK_WRITE applies to all blocks in the range of cwa_offset to the
   length of cwa_data, then each of the target blocks MUST have the same
   cg_gen_id and cg_client_id.  The client SHOULD present the smallest
   set of blocks as possible to meet this requirement.


   // Is the DS supposed to vet all blocks first or proceed to the first
   // error?  Or do all blocks and return an array of errors?  (This
   // last one is a no-go.)  Also, if we do the vet first, what happens
   // if a CHUNK_WRITE comes in after the vetting?  Are we to lock the
   // file during this process.  Even if we do that, we still have the
   // issue of multiple DSes.
   //
   // -- TH

## Operation 77: ROLLBACK_OPEN - Reserve a byte range for writing

### ARGUMENTS

~~~ xdr
   /// struct ROLLBACK_OPEN4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4        roa_stateid;
   ///     ffv2_key4       roa_key;
   ///     uint32_t        roa_client_id;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 46

### RESULTS

~~~ xdr
   /// union ROLLBACK_OPEN4res switch (nfsstat4 ror_status) {
   ///     case NFS4_OK:
   ///         /* New CURRENT_FH: opened client file */
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 47

### DESCRIPTION

   ROLLBACK_OPEN is a new operation to open a per client file for
   staging of chunks to the data file and populates the current
   filehandle for it.  As the reservation file is not visible in the
   server namespace, the client MUST issue a GETFH (see Section 18.8 of
   {{RFC8881}}) to get the filehandle.  The client file MUST have the
   exact same authorization as the data file (see Section 2.8.1 of
   {{RFC8881}}), which means the attributes mode, owner, owner_group, acl,
   dacl, and sacl MUST track those of the file.  I.e., they MUST NOT be
   modified by SETATTR on the client file and if they are modified on
   the data file, they MUST be modified equivalently on the client file.
   Finally, the values of time_access, time_backup, time_create,
   time_metadata, time_modify, and change MUST initially be those of the
   data file, but they MUST be tracked separately from the data file.

   ROLLBACK_OPEN MUST check for write access just like the WRITE
   operation.  I.e., if the owner does not have write permissions, if it
   is a read-only filesystem, etc, the appropriate error MUST be
   returned to the ROLLBACK_OPEN operation.

   The metadata server MUST persist the roa_key and the roa_client_id in
   order to authenticate subsequent operations on the client file.
   These are not visible attributes for the client file.  The metadata
   server MUST not reveal the roa_key in a GETATTR result.  If the
   metadata server loses the roa_key, then the data server MUST allow
   for local administrative action to close the client file Note that
   such means are beyond the scope of this document.

   The ra_stateid follows the rules for a WRITE request for pNFS (see
   Section 2.3.1 of {{I-D.haynes-nfsv4-flexfiles-v2}}).  I.e., an anonymous stateid is
   presented.

   ROLLBACK_OPEN can also be used to recover a client file.  The user
   has to have access to the underlying file in order to recover the
   reservation.  If the client file already exists, the roa_key MUST
   match that which was persisted in the original ROLLBACK_OPEN
   operation to create the client file.  The roa_client_id MUST also
   match that of which was persisted in the original ROLLBACK_OPEN
   operation to create the client file.

   If the roa_key does not match that peristed, then the server MUST
   send back the error NFS4ERR_PERM.  The client can use GETATTR to
   determine if this was due to normal file system semantics or a
   mismatched ffv2_key4.

## Operation 78: ROLLBACK_LIST - Get information on a byte range for
      writing

### ARGUMENTS

~~~ xdr
   /// struct ROLLBACK_LIST4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4        ria_stateid;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 48

### RESULTS

~~~ xdr
   /// struct rollback_info4 {
   ///     uint32_t       ri_client_id;
   ///     nfs_fh4        ri_fh;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 49

~~~ xdr
   /// struct ROLLBACK_LIST4resok {
   ///     rollback_info4  rlr_rollbacks<>;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 50

~~~ xdr
   /// union ROLLBACK_LIST4res switch (nfsstat4 rlr_status) {
   ///     case NFS4_OK:
   ///         ROLLBACK_LIST4resok         rlr_resok4;
   ///     default:
   ///         void;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 51

### DESCRIPTION

   ROLLBACK_LIST is a new operation to list the open client rollback
   files for the current filehandle.  As shown in Figure 48, a stateid
   that follows the rules of Section 9.6.3 MUST be presented.

   The result is an array of rollback_info4 (see Figure 49).  The
   ri_client_id allows the metadata server to determine which
   reservations belonged to a dead client.  The ffv2_key4 associated
   with the reservation file MUST NOT be sent back in the results.

## Operation 80: ROLLBACK_CLOSE - Release reservation on a byte range
      for writing

### ARGUMENTS

~~~ xdr
   /// struct ROLLBACK_CLOSE4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4        rra_stateid;
   ///     uint32_t        rra_reservation_id;
   ///     ffv2_key4       rra_key;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 52

### RESULTS

~~~ xdr
   /// struct ROLLBACK_CLOSE4res {
   ///     nfsstat4 rrr_status;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 53

### DESCRIPTION

   ROLLBACK_CLOSE is a new operation to release a reservation on a file.
   The user has to have access to the underlying file in order to
   release the reservation.  For the given reservation identified by
   rra_reservation_id (see Figure 52), the rra_key MUST match that which
   was persisted in the original ROLLBACK_OPEN operation to create the
   reservation.  As shown in Figure 52, a stateid that follows the rules
   of Section 9.6.3 MUST be presented.

   If there is no matching reservation for the rra_reservation_id, then
   the server MUST send back the error NFS4ERR_NOENT.  If the rra_key
   does not match that peristed, then the server MUST send back the
   error NFS4ERR_PERM.  The client can use GETATTR to determine if this
   was due to normal file system semantics or a mismatched ffv2_key4.

   The state of fattr4reserved_state for the reservation file MUST be
   persisted to NFS4_ROLLBACK_OPEND_RELEASED.

# New NFSv4.2 Callback Operations

~~~ xdr
   ///
   /// /* New callback operations for Erasure Coding start here */
   ///        CB_CHUNK_REPAIR                 = 16,
   ///
~~~
{: #fig-X title="The X" }

                     Figure 54: Callback Operations XDR

 | Callback Operation | Number | Description  |
 | ---
 | CB_CHUNK_REPAIR    | 16     | Section 10.1 |
{: #tbl-X title="X"}

                   Table 6: Protocol Callback Operation
                               Definitions

## Operation 16: CB_CHUNK_REPAIR - Repair a reservation of a byte
       range for writing

###  ARGUMENTS

~~~ xdr
   /// struct CB_CHUNK_REPAIR4args {
   ///     /* CURRENT_FH: file */
   ///     stateid4             crra_stateid;
   ///     uint32_t             crra_reservation_id;
   ///     ffv2_key4            crra_key;
   ///     ffv2_coding_type4    crra_type;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 55

###  RESULTS

~~~ xdr
   /// struct CB_CHUNK_REPAIR4res {
   ///     nfsstat4 crrr_status;
   /// };
~~~
{: #fig-X title="The X" }

                                 Figure 56

###  DESCRIPTION

   CB_CHUNK_REPAIR is a new callback operation to request that the
   client repair a reservation on a file.  The user has to have access
   to the underlying file in order to release the reservation.  For the
   given reservation identified by rra_reservation_id (see Figure 55),
   the crra_key MUST match that which was persisted in the original
   ROLLBACK_OPEN operation to create the reservation.  As shown in
   Figure 55, a stateid that follows the rules of Section 9.6.3 MUST be
   presented.

   If the client does not support the ROLLBACK_OPEN family of
   operations, it MUST return an error of NFS4ERR_NOTSUPP.  Note that
   this is most likely going to occur as in this case it will not
   support CB_CHUNK_REPAIR.  If the client does not support the
   crra_type for the erasure coding type, then it MUST return an error
   of NFS4ERR_CODING_NOT_SUPPORTED.

#  Extraction of XDR

This document contains the External Data Representation (XDR) {{RFC4506}}
description of the flexible file layout type.  The XDR description is
embedded in this document in a way that makes it simple for the reader to
extract into a ready-to-compile form.  The reader can feed this document
into the shell script in {{fig-extract}} to produce the machine-readable
XDR description of the flexible file layout type.

~~ shell
#!/bin/sh
grep '^ *///' $* | sed 's?^ */// ??' | sed 's?^ *///$??'
~~
{: #fig-extract title="extract.sh"}

That is, if the above script is stored in a file called "extract.sh"
and this document is in a file called "spec.txt", then the reader can
run the script as in {{fig-extract-example}}.

~~ shell
sh extract.sh < spec.txt > flex_files2_prot.x
~~
{: #fig-extract-example title="Example use of extract.sh"}

The effect of the script is to remove leading blank space from each
line, plus a sentinel sequence of "///".
   
The embedded XDR file header follows.  Subsequent XDR descriptions
with the sentinel sequence are embedded throughout the document.

Note that the XDR code contained in this document depends on types
from the NFSv4.2 nfs4_prot.x file (generated from {{RFC7863}}) and
the Flexible File Layout Type flexfiles-v2.x file (generated from
{{I-D.haynes-nfsv4-flexfiles-v2}}).  This includes both nfs types that
end with a 4, such as offset4, length4, etc., as well as more generic
types such as uint32_t and uint64_t.

While the XDR can be appended to that from {{RFC7863}}, the various
code snippets belong in their respective areas of that XDR.

12.  Security Considerations

This document has the same security considerations as
both Flexible File Layout Type version 2 (see Section 15 of
{{I-D.haynes-nfsv4-flexfiles-v2}}) and NFSv4.2 (see Section 17 of
{{RFC7862}}).

#  IANA Considerations

This document introduces the 'Flexible File Version 2 Layout Type Erasure
Coding Type Registry'.  This document defines the FFV2_CODING_MIRRORED
type for Client-Side Mirroring (see {{tbl-coding-types}}).

 | Erasure Coding Type Name | Value | RFC      | How | Minor Versions    |
 | ---
 | FFV2_CODING_MIRRORED     | 1     | RFCTBD10 | L   | 2        |
{: #tbl-coding-types title="Flexible File Version 2 Layout Type Erasure Coding Type Assignments"}

# Acknowledgments
{:numbered="false"}

The following from Hammerspace were instrumental in driving Flexible
File Version 2 Layout Type: David Flynn, Trond Myklebust, Tom Haynes,
Didier Feron, Jean-Pierre Monchanin, Pierre Evenou, and Brian
Pawlowski.

Christoph Helwig was instrumental in making sure Flexible File
Version 2 Layout Type was applicable to more than one Erasure Coding
Type.

Robin Battey reviewed the Erasure Coding approach and provided expert
feedback.

Chris Inacio and Brian Pawlowski helped guide this process.
