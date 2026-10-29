# EA SPORTS FC 27 update 1.8c.cab1.
#
# An optional result wrapper dereferences NULL at main+0x804e358, observed
# after the offline notice and during menu loading. Its earlier attribution
# to EA services is unconfirmed: adjacent code checks VP8 video metadata.
# Keep the original copy on success and take cleanup/status for an empty
# result. The cave must store all of Q0, not D0 and D1: D1 belongs to Q1.
fc27_null_result = (
    0x804E358,
    '080340f90001c03d080940f9889600f9886204910001803d',
    'd80000b4080340f928bb86151f2003d51f2003d51f2003d5',
    'offline async result may be NULL: guard the menu result copy (SIGSEGV main+0x804e358)',
)

# Cleanup receives the callback's optional job in X0. The original release
# dereferences X0+0x10, so an empty callback must skip that release as well.
fc27_result_cleanup = (
    0x804E370,
    '8c6bef97',
    '30bb8615',
    'release the async callback job only when X0 is non-NULL',
)

# Executable cave in the second (back) patch area. Addresses are guest-relative
# to the module base; the final two branches return to main+0x804e370.
fc27_result_cave = (
    0xE1FD000,
    'e80000b40001c03d080940f9889600f9886204910001803dd6447916d5447916',
    'result-copy vtable guard: valid path copies, NULL vtable skips',
)
fc27_cleanup_cave = (
    0xE1FD030,
    '400000b45bb06896cf447916',
    'guard the optional callback job, preserve the original release and continuation',
)

CUTS = {
    'fb81983aa1cc3a2e97402497e2ca6528': [fc27_null_result, fc27_result_cleanup],
}
CODE = {
    'fb81983aa1cc3a2e97402497e2ca6528': [fc27_result_cave, fc27_cleanup_cave],
}
OBS = {}
FRAME_STEP = {}
MATCH_CUTS = {}
