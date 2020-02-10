#include <cstdlib>

#include "Application.h"

#include "core_workload.h"
#include "ycsbwrappers.h"

#include "hdrhist.hpp"

#include "rocksdb/db.h"

#include <strstream>
#include <filesystem>
#include <chrono>

using namespace std;

template< class DB >
inline void performYcsbRead(DB db, ycsbc::CoreWorkload& workload, bool verbose) {
    ycsbcwrappers::TxRead txread = ycsbcwrappers::TransactionRead(workload);
    if (!workload.read_all_fields()) {
        cerr << db.name << " error: not reading all fields unsupported" << endl;
        exit(-1);
    }
    if (verbose) {
        cerr << db.name << " [op] READ " << txread.table << " " << txread.key << " { all fields }" << endl;
    }
    // TODO use the table name?
    db.query(txread.key);
}

template< class DB >
inline void performYcsbInsert(DB db, ycsbc::CoreWorkload& workload, bool verbose) {
    ycsbcwrappers::TxInsert txinsert = ycsbcwrappers::TransactionInsert(workload);
    if (txinsert.values->size() != 1) {
        cerr << db.name << " error: only fieldcount=1 is supported" << endl;
        exit(-1);
    }
    const std::string& value = (*txinsert.values)[0].second;
    if (verbose) {
        cerr << db.name << " [op] INSERT " << txinsert.table << " " << txinsert.key << " " << value << endl;
    }
    // TODO use the table name?
    db.insert(txinsert.key, value);
}

template< class DB >
inline void performYcsbUpdate(DB db, ycsbc::CoreWorkload& workload, bool verbose) {
    ycsbcwrappers::TxUpdate txupdate = ycsbcwrappers::TransactionUpdate(workload);
    if (!workload.write_all_fields()) {
        cerr << db.name << " error: not writing all fields unsupported" << endl;
        exit(-1);
    }
    if (txupdate.values->size() != 1) {
        cerr << db.name << " error: only fieldcount=1 is supported" << endl;
        exit(-1);
    }
    const std::string& value = (*txupdate.values)[0].second;
    if (verbose) {
        cerr << db.name << " [op] UPDATE " << txupdate.table << " " << txupdate.key << " " << value << endl;
    }
    // TODO use the table name?
    db.update(txupdate.key, value);
}

template< class DB >
void ycsbLoad(DB db, ycsbc::CoreWorkload& workload, int num_ops, bool verbose) {
    cerr << db.name << " [step] loading (num ops: " << num_ops << ")" << endl;

    auto clock_start = chrono::high_resolution_clock::now();
    for (int i = 0; i < num_ops; ++i) {
        performYcsbInsert(db, workload, verbose);
    }

    cerr << db.name << " [step] sync" << endl;
    db.sync();

    auto clock_end = chrono::high_resolution_clock::now();
    long long bench_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(clock_end - clock_start).count();

    double ops_per_sec = ((double) num_ops) / (((double) bench_ns) / 1000000000);

    cerr << db.name << " [step] loading complete" << endl;
    cout << "db(load)\tduration(ns)\toperations\tops/s" << endl;
    cout << db.name << "\t" << bench_ns << "\t" << num_ops << "\t" << ops_per_sec << endl;
}

template< class DB >
void ycsbRun(
    DB db,
    ycsbc::CoreWorkload& workload,
    int num_ops,
    int sync_interval_ms,
    bool verbose) {

    cerr << db.name << " [step] running experiment (num ops: " << num_ops << ", sync interval " <<
        sync_interval_ms << "ms)" << endl;

    // TODO: sync every k seconds
 
    auto clock_start = chrono::high_resolution_clock::now();
    auto clock_prev = clock_start;
    auto clock_last_sync = clock_start;

    for (int i = 0; i < num_ops; ++i) {
        auto next_operation = workload.NextOperation();
        switch (next_operation) {
            case ycsbc::READ:
                performYcsbRead(db, workload, verbose);
                break;
            case ycsbc::UPDATE:
                performYcsbUpdate(db, workload, verbose);
                break;
            case ycsbc::INSERT:
                performYcsbInsert(db, workload, verbose);
                break;
            case ycsbc::SCAN:
                cerr << "error: operation SCAN unimplemented" << endl;
                exit(-1);
                break;
            case ycsbc::READMODIFYWRITE:
                cerr << "error: operation READMODIFYWRITE unimplemented" << endl;
                exit(-1);
                break;
            default:
                cerr << "error: invalid NextOperation" << endl;
                exit(-1);
        }

        auto clock_op_completed = chrono::high_resolution_clock::now();

        if (std::chrono::duration_cast<std::chrono::milliseconds>(
            clock_op_completed - clock_last_sync).count() > sync_interval_ms) {

            cerr << db.name << " [op] sync (completed " << i << " ops)" << endl;
            db.sync();

            auto sync_completed = chrono::high_resolution_clock::now();
            clock_last_sync = sync_completed;
            clock_prev = sync_completed;
        } else {
            clock_prev = clock_op_completed;
        }
    }

    auto clock_end = chrono::high_resolution_clock::now();
    long long bench_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(clock_end - clock_start).count();

    double ops_per_sec = ((double) num_ops) / (((double) bench_ns) / 1000000000);

    cerr << db.name << " [step] experiment complete" << endl;
    cout << "db\tduration(ns)\toperations\tops/s" << endl;
    cout << db.name << "\t" << bench_ns << "\t" << num_ops << "\t" << ops_per_sec << endl;
}

class VeribetrkvFacade {
protected:
    Application& app;

public:
    static const string name;

    VeribetrkvFacade(Application& app) : app(app) { }

    inline void query(const string& key) {
        app.Query(key);
    }

    inline void insert(const string& key, const string& value) {
        app.Insert(key, value);
    }

    inline void update(const string& key, const string& value) {
        app.Insert(key, value);
    }

    inline void sync() {
        app.Sync();
    }
};

const string VeribetrkvFacade::name = string("veribetrkv");

class RocksdbFacade {
protected:
    rocksdb::DB& db;
    
public:
    static const string name;

    RocksdbFacade(rocksdb::DB& db) : db(db) { }

    inline void query(const string& key) {
        static struct rocksdb::ReadOptions roptions = rocksdb::ReadOptions();
        string value;
        rocksdb::Status status = db.Get(roptions, rocksdb::Slice(key), &value);
        assert(status.ok() || status.IsNotFound()); // TODO is it expected we're querying non-existing keys?
    }

    inline void insert(const string& key, const string& value) {
        static struct rocksdb::WriteOptions woptions = rocksdb::WriteOptions();
        woptions.disableWAL = true;
        rocksdb::Status status = db.Put(woptions, rocksdb::Slice(key), rocksdb::Slice(value));
        assert(status.ok());
    }

    inline void update(const string& key, const string& value) {
        static struct rocksdb::WriteOptions woptions = rocksdb::WriteOptions();
        woptions.disableWAL = true;
        rocksdb::Status status = db.Put(woptions, rocksdb::Slice(key), rocksdb::Slice(value));
        assert(status.ok());
    }

    inline void sync() {
        static struct rocksdb::FlushOptions foptions = rocksdb::FlushOptions();
        rocksdb::Status status = db.Flush(foptions);
        assert(status.ok());
    }
};

const string RocksdbFacade::name = string("rocksdb");

int main(int argc, char* argv[]) {
    bool verbose = false;
 
    if (argc != 3) {
        cerr << "error: expects two arguments: the workload spec, and the persistent data directory" << endl;
        exit(-1);
    }

    std::string workload_filename(argv[1]);
    std::string base_directory(argv[2]);
    // (unsupported on macOS 10.14) std::filesystem::create_directory(base_directory);
    // check that base_directory is empty
    int status = std::system(("[ \"$(ls -A " + base_directory + ")\" ]").c_str());
    if (status == 0) {
        cerr << "error: " << base_directory << " appears to be non-empty";
        exit(-1);
    }

    utils::Properties props = ycsbcwrappers::props_from(workload_filename);
    unique_ptr<ycsbc::CoreWorkload> workload(ycsbcwrappers::new_workload(props));
    int record_count = stoi(props[ycsbc::CoreWorkload::RECORD_COUNT_PROPERTY]);

    auto properties_map = props.properties();
    if (properties_map.find("syncintervalms") == properties_map.end()) {
        cerr << "error: spec must provide syncintervalms" << endl;
        exit(-1);
    }
    int sync_interval_ms = stoi(props["syncintervalms"]);

    {
        /* veribetrkv */ std::string veribetrfs_filename = base_directory + "veribetrfs.img";
        // /* veribetrkv */ (unsupported on macOS 10.14) std::filesystem::remove_all(veribetrfs_filename);
        /* veribetrkv */ Mkfs(veribetrfs_filename);
        /* veribetrkv */ Application app(veribetrfs_filename);
        /* veribetrkv */ VeribetrkvFacade db(app);
    
        ycsbLoad(db, *workload, record_count, verbose);
        int num_ops = stoi(props[ycsbc::CoreWorkload::OPERATION_COUNT_PROPERTY]);
        ycsbRun(db, *workload, num_ops, sync_interval_ms, verbose);
    }

    {
        /* rocksdb */ static string rocksdb_path = base_directory + "rocksdb.db";
        // /* rocksdb */ (unsupported on macOS 10.14) std::filesystem::remove_all(rocksdb_path);

        /* rocksdb */ rocksdb::DB* rocks_db;
        /* rocksdb */ rocksdb::Options options;
        /* rocksdb */ options.create_if_missing = true;
        /* rocksdb */ options.error_if_exists = true;
        /* rocksdb */ rocksdb::Status status = rocksdb::DB::Open(options, rocksdb_path, &rocks_db);
        /* rocksdb */ assert(status.ok());
        /* rocksdb */ RocksdbFacade db(*rocks_db);

        ycsbLoad(db, *workload, record_count, verbose);
        int num_ops = stoi(props[ycsbc::CoreWorkload::OPERATION_COUNT_PROPERTY]);
        ycsbRun(db, *workload, num_ops, sync_interval_ms, verbose);
    }
}

